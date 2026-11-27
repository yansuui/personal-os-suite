import Foundation
import XCTest
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

struct URLProtocolStubCleanupError: Error, CustomStringConvertible {
    let waitResult: XCTWaiter.Result
    let invalidated: Bool
    let pendingCompletions: Int
    let timeout: TimeInterval

    var description: String {
        "URLSession 清理未完成：waiter=\(waitResult)，didBecomeInvalid=\(invalidated)，待 completion=\(pendingCompletions)，等待上限=\(timeout)s"
    }
}

/// 等待 session 失效及测试明确登记的 completion，不假设二者回调顺序。
final class URLProtocolStubSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var pendingCompletions = 0
    private var waiters: [XCTestExpectation] = []

    var isCleanupComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated && pendingCompletions == 0
    }

    func expectTaskCompletion() {
        lock.lock()
        pendingCompletions += 1
        lock.unlock()
    }

    func taskCompleted() {
        lock.lock()
        guard pendingCompletions > 0 else {
            lock.unlock()
            XCTFail("收到未登记或重复的 task completion")
            return
        }
        pendingCompletions -= 1
        let pending = takeReadyWaiters()
        lock.unlock()
        for waiter in pending { waiter.fulfill() }
    }

    func waitForInvalidation(timeout: TimeInterval = 5) async throws {
        let waiter = XCTestExpectation(description: "session 失效且已登记 completion 排空")
        register(waiter)
        defer { unregister(waiter) }
        let result = await XCTWaiter.fulfillment(of: [waiter], timeout: timeout)
        guard result == .completed, isCleanupComplete else {
            throw cleanupError(result, timeout: timeout)
        }
    }

    private func register(_ waiter: XCTestExpectation) {
        lock.lock()
        if invalidated && pendingCompletions == 0 {
            lock.unlock()
            waiter.fulfill()
        } else {
            waiters.append(waiter)
            lock.unlock()
        }
    }

    private func unregister(_ waiter: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        waiters.removeAll { $0 === waiter }
    }

    /// 调用方已持有 lock。
    private func takeReadyWaiters() -> [XCTestExpectation] {
        guard invalidated && pendingCompletions == 0 else { return [] }
        let pending = waiters
        waiters = []
        return pending
    }

    private func cleanupError(_ result: XCTWaiter.Result, timeout: TimeInterval) -> URLProtocolStubCleanupError {
        lock.lock()
        defer { lock.unlock() }
        return URLProtocolStubCleanupError(waitResult: result, invalidated: invalidated,
            pendingCompletions: pendingCompletions, timeout: timeout)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        invalidated = true
        let pending = takeReadyWaiters()
        lock.unlock()
        for waiter in pending { waiter.fulfill() }
    }
}

/// 全局桩注册表：记录收到的 URLRequest，并把响应交回 URLProtocol。
///
/// 只在测试进程内使用；加锁是因为 URLSession 的回调线程与测试线程不同。
final class URLProtocolStubRegistry: @unchecked Sendable {
    private enum CleanupError: Error { case alreadyInProgress }

    static let shared = URLProtocolStubRegistry()

    private let lock = NSLock()
    private var handler: ((URLRequest) -> StubResponse)?
    private var recorded: [URLRequest] = []
    private var sessions: [(URLSession, URLProtocolStubSessionDelegate)] = []
    private var pendingCleanup: [(URLSession, URLProtocolStubSessionDelegate)] = []
    private var cleanupInProgress = false

    /// 清理未实际排空时报告失败并保留旧状态；负向测试可关闭预期失败的报告。
    @discardableResult
    func reset(reportFailure: Bool = true) -> Bool {
        lock.lock()
        guard !cleanupInProgress, pendingCleanup.allSatisfy({ $0.1.isCleanupComplete }) else {
            lock.unlock()
            if reportFailure { XCTFail("旧 session 尚未排空，不能 reset 桩注册表") }
            return false
        }
        defer { lock.unlock() }
        pendingCleanup = []
        handler = nil
        recorded = []
        return true
    }

    func trackSession(_ session: URLSession, delegate: URLProtocolStubSessionDelegate) {
        lock.lock()
        defer { lock.unlock() }
        sessions.append((session, delegate))
    }

    private func takeSessions() throws -> [(URLSession, URLProtocolStubSessionDelegate)] {
        lock.lock()
        defer { lock.unlock() }
        guard !cleanupInProgress else { throw CleanupError.alreadyInProgress }
        cleanupInProgress = true
        let pending = sessions
        sessions = []
        pendingCleanup = pending
        return pending
    }

    private func restoreSessionsAfterFailure(_ pending: [(URLSession, URLProtocolStubSessionDelegate)]) {
        lock.lock()
        defer { lock.unlock() }
        sessions.append(contentsOf: pending)
        cleanupInProgress = false
    }

    private func markCleanupComplete() {
        lock.lock()
        defer { lock.unlock() }
        pendingCleanup = []
        cleanupInProgress = false
    }

    /// 取消整个 session；失效和已登记 completion 都排空后才可复用注册表。
    func invalidateSessions(timeout: TimeInterval = 5) async throws {
        let pending = try takeSessions()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        for (session, _) in pending { session.invalidateAndCancel() }
        do {
            for (_, delegate) in pending {
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                try await delegate.waitForInvalidation(timeout: remaining)
            }
            markCleanupComplete()
        } catch {
            restoreSessionsAfterFailure(pending)
            throw error
        }
    }

    func setHandler(_ handler: @escaping (URLRequest) -> StubResponse) {
        lock.lock()
        guard !cleanupInProgress, pendingCleanup.allSatisfy({ $0.1.isCleanupComplete }) else {
            lock.unlock()
            XCTFail("旧 session 尚未排空，不能更换桩 handler")
            return
        }
        self.handler = handler
        lock.unlock()
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
