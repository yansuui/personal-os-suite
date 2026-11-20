import Foundation

/// 基于 `URLSession` 的 POSAPI 实现。
///
/// 约定（CONTRACT §3 §6）：
/// - 除 `/v1/pair`（用 `x-pair-secret`）外，所有请求带 `Authorization: Bearer <token>`；
/// - 分档超时：普通请求 15s，`timeline` 长轮询 `max(30, waitSeconds + 10)`；
/// - 错误映射：401/403 → `.unauthorized`，409 → `.conflict`，其它非 2xx → `.server`，
///   解码失败 → `.decoding`，网络错误 → `.transport`；
/// - 任何日志/错误描述都不得包含 token 正文（本实现不在任何地方打印请求或响应）。
public struct URLSessionPOSAPI: POSAPI, Sendable {
    private let config: ServerConfig
    private let urlSession: URLSession

    /// 普通请求超时（秒）。
    private static let regularTimeout: TimeInterval = 15
    /// 长轮询超时下限（秒）；实际值取 `max(30, waitSeconds + 10)`。
    private static let longPollFloor: Int = 30

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.urlSession = session
    }

    // MARK: - POSAPI

    public func pair(secret: String, _ request: PairRequest) async throws -> AuthSession {
        let body = try encode(request)
        let urlRequest = try makeRequest(
            method: "POST",
            path: "v1/pair",
            headers: [
                "accept": "application/json",
                "content-type": "application/json",
                // 配对用独立密钥头，不带 Bearer。
                "x-pair-secret": secret
            ],
            timeout: Self.regularTimeout,
            body: body
        )
        let data = try await send(urlRequest)
        return try decode(AuthSession.self, from: data)
    }

    public func me(_ session: AuthSession) async throws -> DeviceInfo {
        let request = try authorizedRequest(method: "GET", path: "v1/me", session: session, timeout: Self.regularTimeout)
        let data = try await send(request)
        return try decode(DeviceEnvelope.self, from: data).device
    }

    public func timeline(_ session: AuthSession, after: Int, waitSeconds: Int) async throws -> TimelinePage {
        let wait = max(0, waitSeconds)
        let timeout = TimeInterval(max(Self.longPollFloor, wait + 10))
        let query = [
            URLQueryItem(name: "after", value: String(max(0, after))),
            URLQueryItem(name: "wait", value: String(wait))
        ]
        let request = try authorizedRequest(
            method: "GET",
            path: "v1/timeline/events",
            query: query,
            session: session,
            timeout: timeout
        )
        let data = try await send(request)
        return try decode(TimelinePage.self, from: data)
    }

    public func sendMessage(_ session: AuthSession, _ request: SendMessageRequest) async throws -> SendMessageAck {
        // 幂等键由调用方生成；这里原样编码，重试请求体逐字节一致。
        let body = try encode(request)
        let urlRequest = try authorizedRequest(
            method: "POST",
            path: "v1/chat/messages",
            session: session,
            timeout: Self.regularTimeout,
            body: body
        )
        let data = try await send(urlRequest)
        let envelope = try decode(ChatCreateEnvelope.self, from: data)
        return SendMessageAck(messageID: envelope.message.id, runID: nil)
    }

    public func tasks(_ session: AuthSession) async throws -> TaskList {
        let request = try authorizedRequest(method: "GET", path: "v1/tasks", session: session, timeout: Self.regularTimeout)
        let data = try await send(request)
        return try decode(TaskList.self, from: data)
    }

    public func approve(_ session: AuthSession, taskID: String, approved: Bool, note: String?) async throws {
        // v1 的 POST /v1/tasks/:id/approve 无条件批准（请求体只作说明，没有拒绝分支）。
        // 若 approved == false 仍打 /approve，界面上的「拒绝」会静默变成「批准」，
        // 因此在服务端补出 reject 端点前，拒绝一律映射为「取消该任务」。
        // CONTRACT-DEVIATION: reject 语义借道 /cancel，等云端 ApprovalService 落地后替换。
        guard approved else {
            let cancel = try authorizedRequest(
                method: "POST",
                path: "v1/tasks/\(taskID)/cancel",
                session: session,
                timeout: Self.regularTimeout
            )
            _ = try await send(cancel)
            return
        }
        let body = try encode(ApproveRequest(approved: approved, note: note))
        let request = try authorizedRequest(
            method: "POST",
            path: "v1/tasks/\(taskID)/approve",
            session: session,
            timeout: Self.regularTimeout,
            body: body
        )
        _ = try await send(request)
    }

    public func submitVerdict(_ session: AuthSession, taskID: String, verdict: String, note: String?) async throws {
        let body = try encode(VerdictRequest(verdict: verdict, note: note))
        let request = try authorizedRequest(
            method: "POST",
            path: "v1/tasks/\(taskID)/verdict",
            session: session,
            timeout: Self.regularTimeout,
            body: body
        )
        _ = try await send(request)
    }

    public func context(_ session: AuthSession) async throws -> ContextSnapshot {
        let request = try authorizedRequest(method: "GET", path: "v1/context", session: session, timeout: Self.regularTimeout)
        let data = try await send(request)
        return try decode(ContextSnapshot.self, from: data)
    }

    public func presence(_ session: AuthSession) async throws -> Presence {
        let request = try authorizedRequest(method: "GET", path: "v1/presence", session: session, timeout: Self.regularTimeout)
        let data = try await send(request)
        return try decode(Presence.self, from: data)
    }

    // MARK: - 请求构造

    private func authorizedRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        session: AuthSession,
        timeout: TimeInterval,
        body: Data? = nil
    ) throws -> URLRequest {
        var headers = ["accept": "application/json"]
        if body != nil { headers["content-type"] = "application/json" }
        // token 只出现在请求头；不写入日志、错误描述或 URL。
        headers["authorization"] = "Bearer \(session.token)"
        return try makeRequest(method: method, path: path, query: query, headers: headers, timeout: timeout, body: body)
    }

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        headers: [String: String],
        timeout: TimeInterval,
        body: Data? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw POSAPIError.transport("服务器地址无效")
        }
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = basePath + "/" + trimmedPath
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw POSAPIError.transport("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        return request
    }

    // MARK: - 发送与解码

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw POSAPIError.transport("响应不是 HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.httpError(status: http.statusCode, data: data)
            }
            return data
        } catch let error as POSAPIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw POSAPIError.transport("请求已取消")
        } catch {
            // 只保留系统错误描述：URLError 文案不含请求头，不会泄露 token。
            throw POSAPIError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw POSAPIError.decoding("响应解析失败：\(error)")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            // 编码失败属于实现缺陷，复用 `.decoding`（错误文案不含 token）。
            throw POSAPIError.decoding("请求编码失败：\(error)")
        }
    }

    /// 非 2xx → POSAPIError。409 只上报冲突，绝不自动重试或合并（CONTRACT §3 行为 3）。
    private static func httpError(status: Int, data: Data) -> POSAPIError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let code = (envelope?.error?.code ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = (envelope?.error?.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401, 403:
            return .unauthorized
        case 409:
            return .conflict(message.isEmpty ? "版本冲突，请刷新后重试" : message)
        default:
            return .server(
                status: status,
                code: code.isEmpty ? "http-\(status)" : code,
                message: message.isEmpty ? "请求失败（HTTP \(status)）" : message
            )
        }
    }
}

// MARK: - 响应外壳

/// `GET /v1/me` → `{ device }`。
private struct DeviceEnvelope: Decodable {
    let device: DeviceInfo
}

/// `POST /v1/chat/messages` → `{ message, duplicate }`；只取 message.id。
private struct ChatCreateEnvelope: Decodable {
    struct Message: Decodable {
        let id: String
    }

    let message: Message
}

/// 服务端错误体 `{ error: { code, message } }`。
private struct ErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let code: String?
        let message: String?
    }

    let error: Payload?
}

/// `POST /v1/tasks/:id/approve` 请求体（服务端当前不读取，仅作为说明性字段）。
private struct ApproveRequest: Encodable {
    let approved: Bool
    let note: String?
}

/// `POST /v1/tasks/:id/verdict` 请求体，服务端读取 `verdict` 与可选 `note`。
private struct VerdictRequest: Encodable {
    let verdict: String
    let note: String?
}
