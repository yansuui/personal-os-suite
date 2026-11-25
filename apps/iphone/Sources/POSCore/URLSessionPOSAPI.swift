import Foundation

/// v2 HTTP 客户端。普通请求 15s；长轮询等待 0...25s，超时至少 wait+10/30s。
/// 不记录请求、响应或凭据；409 向上抛，由界面刷新。
public struct URLSessionPOSAPI: POSAPI, Sendable {
    private let config: ServerConfig
    private let urlSession: URLSession
    private static let regularTimeout: TimeInterval = 15

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.urlSession = session
    }

    public func health() async throws -> HealthResponse {
        let request = try makeRequest(method: "GET", path: "v2/health", timeout: Self.regularTimeout)
        let response = try decode(HealthResponse.self, from: await send(request))
        guard response.ok, response.protocolVersion == 2 else {
            throw POSAPIError.decoding("服务器未提供 v2 协议")
        }
        return response
    }

    public func pair(secret: String, _ request: PairRequest) async throws -> AuthSession {
        let urlRequest = try makeRequest(
            method: "POST", path: "v2/pair", headers: ["x-pair-secret": secret],
            timeout: Self.regularTimeout, body: encode(request)
        )
        return try decode(AuthSession.self, from: await send(urlRequest))
    }

    public func me(_ session: AuthSession) async throws -> DeviceInfo {
        let request = try authorizedRequest(method: "GET", path: "v2/me", session: session)
        return try decode(DeviceEnvelope.self, from: await send(request)).device
    }

    public func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation {
        let request = try authorizedRequest(
            method: "POST", path: "v2/conversations", session: session,
            body: encode(CreateConversationRequest(title: title))
        )
        return try decode(ConversationEnvelope.self, from: await send(request)).conversation
    }

    public func conversations(_ session: AuthSession) async throws -> [Conversation] {
        let request = try authorizedRequest(method: "GET", path: "v2/conversations", session: session)
        return try decode(ConversationsEnvelope.self, from: await send(request)).conversations
    }

    public func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage {
        let wait = min(25, max(0, waitSeconds))
        let after = max(0, after)
        let request = try authorizedRequest(
            method: "GET", path: messagesPath(conversationID),
            query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "wait", value: String(wait))],
            session: session, timeout: TimeInterval(max(30, wait + 10))
        )
        let page = try decode(MessagePage.self, from: await send(request))
        // 缺少会话信息或游标非法时不允许把错误页写入缓存。
        guard page.messages.count <= 200,
              page.messages.allSatisfy({ $0.conversationID == conversationID && $0.seq > after }),
              page.messages.map(\.seq) == page.messages.map(\.seq).sorted(),
              page.nextCursor == (page.messages.last?.seq ?? after) else {
            throw POSAPIError.decoding("消息会话或增量游标无效")
        }
        return page
    }

    public func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck {
        guard !request.clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw POSAPIError.decoding("消息缺少幂等键")
        }
        let urlRequest = try authorizedRequest(
            method: "POST", path: messagesPath(conversationID), session: session, body: encode(request)
        )
        let ack = try decode(SendMessageAck.self, from: await send(urlRequest))
        guard ack.message.conversationID == conversationID,
              ack.message.clientRequestID == request.clientRequestID,
              ack.run.conversationId == conversationID, ack.run.messageId == ack.message.id else {
            throw POSAPIError.decoding("发送确认与会话或幂等键不匹配")
        }
        return ack
    }

    private func messagesPath(_ conversationID: String) throws -> String {
        guard conversationID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw POSAPIError.decoding("会话 ID 无效")
        }
        return "v2/conversations/\(conversationID)/messages"
    }

    private func authorizedRequest(method: String, path: String, query: [URLQueryItem] = [],
                                   session: AuthSession, timeout: TimeInterval = URLSessionPOSAPI.regularTimeout,
                                   body: Data? = nil) throws -> URLRequest {
        try makeRequest(method: method, path: path, query: query,
                        headers: ["authorization": "Bearer \(session.token)"], timeout: timeout, body: body)
    }

    private func makeRequest(method: String, path: String, query: [URLQueryItem] = [],
                             headers: [String: String] = [:], timeout: TimeInterval,
                             body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw POSAPIError.transport("服务器地址无效")
        }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + "/" + path
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        guard let url = components.url else { throw POSAPIError.transport("服务器地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "content-type") }
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw POSAPIError.transport("响应不是 HTTP") }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.httpError(status: http.statusCode, data: data)
            }
            return data
        } catch let error as POSAPIError {
            throw error
        } catch {
            throw POSAPIError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw POSAPIError.decoding("响应解析失败") }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(value)
        } catch { throw POSAPIError.decoding("请求编码失败") }
    }

    private static func httpError(status: Int, data: Data) -> POSAPIError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let code = envelope?.error.code ?? "http-\(status)"
        let message = envelope?.error.message ?? "请求失败（HTTP \(status)）"
        switch status {
        case 401, 403: return .unauthorized
        case 409: return .conflict(message)
        default: return .server(status: status, code: code, message: message)
        }
    }
}

private struct DeviceEnvelope: Decodable { let device: DeviceInfo }
private struct ConversationEnvelope: Decodable { let conversation: Conversation }
private struct ConversationsEnvelope: Decodable { let conversations: [Conversation] }
private struct CreateConversationRequest: Encodable { let title: String? }
private struct ErrorEnvelope: Decodable {
    struct Payload: Decodable { let code: String; let message: String }
    let error: Payload
}
