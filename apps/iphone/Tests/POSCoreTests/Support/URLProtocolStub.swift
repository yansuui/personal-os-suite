import Foundation
import POSCore

/// 桩响应：状态码 + 头 + 体。
struct StubResponse {
    var status: Int = 200
    var headers: [String: String] = ["content-type": "application/json"]
    var body: Data = Data()

    static func json(_ status: Int = 200, _ text: String) -> StubResponse {
        StubResponse(status: status, headers: ["content-type": "application/json"], body: Data(text.utf8))
    }
}

/// 等待 URLSession 真正失效，而不只等待调用方的 Task / AsyncStream 结束。
final class URLProtocolStubSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForInvalidation() async {
        await withCheckedContinuation { register($0) }
    }

    private func register(_ waiter: CheckedContinuation<Void, Never>) {
        lock.lock()
        if invalidated {
            lock.unlock()
            waiter.resume()
        } else {
            waiters.append(waiter)
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        invalidated = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

/// 全局桩注册表：记录收到的 URLRequest，并把响应交回 URLProtocol。
///
/// 只在测试进程内使用；加锁是因为 URLSession 的回调线程与测试线程不同。
final class URLProtocolStubRegistry: @unchecked Sendable {
    static let shared = URLProtocolStubRegistry()

    private let lock = NSLock()
    private var handler: ((URLRequest) -> StubResponse)?
    private var recorded: [URLRequest] = []
    private var sessions: [(URLSession, URLProtocolStubSessionDelegate)] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    func trackSession(_ session: URLSession, delegate: URLProtocolStubSessionDelegate) {
        lock.lock()
        defer { lock.unlock() }
        sessions.append((session, delegate))
    }

    private func takeSessions() -> [(URLSession, URLProtocolStubSessionDelegate)] {
        lock.lock()
        defer { lock.unlock() }
        let pending = sessions
        sessions = []
        return pending
    }

    /// 先取消所有旧 session，再异步等待完成回调，之后才可 reset 共享记录。
    func invalidateSessions() async {
        let pending = takeSessions()
        for (session, _) in pending { session.invalidateAndCancel() }
        for (_, delegate) in pending { await delegate.waitForInvalidation() }
    }

    func setHandler(_ handler: @escaping (URLRequest) -> StubResponse) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func respond(to request: URLRequest) -> StubResponse {
        lock.lock()
        recorded.append(request)
        let handler = self.handler
        lock.unlock()
        guard let handler else {
            return .json(500, #"{"error":{"code":"no-stub","message":"没有设置桩"}}"#)
        }
        return handler(request)
    }
}

/// 不联网的 URLProtocol 桩：拦截所有请求并按注册表回应。
final class URLProtocolStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canInit(with task: URLSessionTask) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = URLProtocolStubRegistry.shared.respond(to: request)
        let url = request.url ?? URL(string: "http://stub.invalid")!
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession 交给 URLProtocol 时会把 httpBody 转成 httpBodyStream，这里统一读出来。
    var stubBody: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    var stubQueryItems: [URLQueryItem] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        return components.queryItems ?? []
    }

    var stubPath: String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        return components.path
    }

    func stubQueryValue(_ name: String) -> String? {
        stubQueryItems.first { $0.name == name }?.value
    }
}

/// 构造一个只走桩的 URLSession。
func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = URLProtocolStubSessionDelegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    URLProtocolStubRegistry.shared.trackSession(session, delegate: delegate)
    return session
}

/// 构造被测 API（所有请求都由 URLProtocolStub 接住，不联网）。
func makeStubAPI(baseURL: URL = URL(string: "http://127.0.0.1:8787")!) -> URLSessionPOSAPI {
    URLSessionPOSAPI(config: ServerConfig(baseURL: baseURL), session: makeStubSession())
}
