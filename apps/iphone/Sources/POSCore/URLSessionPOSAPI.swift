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
        let response = try decode(HealthResponse.self, from: await send(request, isHealthCheck: true))
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
              ack.run.conversationId == conversationID, ack.run.messageId == ack.message.id,
              RunStatus(rawValue: ack.run.status) != nil,
              ack.run.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw POSAPIError.decoding("发送确认与会话、运行状态或幂等键不匹配")
        }
        return ack
    }

    public func run(_ session: AuthSession, runID: String) async throws -> Run {
        let request = try authorizedRequest(method: "GET", path: runsPath(runID), session: session)
        let response = try decode(RunEnvelope.self, from: await send(request))
        try validate(response.run, expectedID: runID)
        return response.run
    }

    public func cancelRun(_ session: AuthSession, runID: String) async throws -> Run {
        let request = try authorizedRequest(method: "POST", path: runsPath(runID) + "/cancel", session: session)
        let response = try decode(RunEnvelope.self, from: await send(request))
        try validate(response.run, expectedID: runID)
        return response.run
    }

    public func capabilities(_ session: AuthSession) async throws -> POSCapabilities {
        let request = try authorizedRequest(method: "GET", path: "v2/capabilities", session: session)
        return try decode(POSCapabilities.self, from: await send(request))
    }

    public func goals(_ session: AuthSession, status: GoalStatus) async throws -> [Goal] {
        var result: [Goal] = []
        var after = 0
        while true {
            let request = try authorizedRequest(method: "GET", path: "v2/goals", query: [
                URLQueryItem(name: "status", value: status.rawValue),
                URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "after", value: String(after))
            ], session: session)
            let page = try decode(GoalsEnvelope.self, from: await send(request))
            guard page.goals.count <= 100,
                  page.goals.allSatisfy({ $0.status == status && $0.revision >= 1 && isResourceID($0.id) }) else {
                throw POSAPIError.decoding("目标列表状态或版本无效")
            }
            result.append(contentsOf: page.goals)
            guard let next = page.nextCursor else { break }
            guard next > after, !page.goals.isEmpty else { throw POSAPIError.decoding("目标列表分页游标无效") }
            // 不将有界读取误报为完整列表；保留旧缓存并明确报告限制。
            guard result.count < 1_000 else { throw POSAPIError.decoding("此状态超过本机 1000 个目标读取上限，列表未完整刷新") }
            after = next
        }
        var byID: [String: Goal] = [:]
        for goal in result { byID[goal.id] = goal }
        return byID.values.sorted { $0.id < $1.id }
    }

    public func goal(_ session: AuthSession, goalID: String) async throws -> GoalDetail {
        let request = try authorizedRequest(method: "GET", path: goalPath(goalID), session: session)
        let detail = try decode(GoalViewEnvelope.self, from: await send(request)).goalView
        guard detail.goal.id == goalID, detail.goal.revision >= 1, detail.viewRevision >= 1,
              Set(detail.tasks.map(\.id)).count == detail.tasks.count,
              detail.tasks.allSatisfy({ $0.goalId == goalID && $0.revision >= 1 && isResourceID($0.id) }),
              detail.summary.completedTasks == detail.tasks.filter({ $0.status == .completed }).count,
              detail.summary.blockedTasks == detail.tasks.filter({ $0.status == .blocked }).count,
              detail.summary.canceledTasks == detail.tasks.filter({ $0.status == .canceled }).count,
              detail.summary.activeTasks == detail.tasks.filter({ $0.status != .canceled }).count,
              detail.summary.completionPercent.map({ (0...100).contains($0) }) ?? true else {
            throw POSAPIError.decoding("目标详情与任务汇总不匹配")
        }
        return detail
    }

    public func createGoal(_ session: AuthSession, _ request: CreateGoalRequest) async throws -> Goal {
        try validateCommandID(request.commandId)
        let urlRequest = try authorizedRequest(method: "POST", path: "v2/goals", session: session, body: encode(request))
        let goal = try decode(GoalEnvelope.self, from: await send(urlRequest)).goal
        guard isResourceID(goal.id), goal.revision >= 1 else { throw POSAPIError.decoding("目标响应无效") }
        return goal
    }

    public func updateGoal(_ session: AuthSession, goalID: String, _ command: GoalCommand) async throws -> Goal {
        try validateCommandID(command.commandId)
        let request = try authorizedRequest(method: "POST", path: goalPath(goalID) + "/commands",
            session: session, body: encode(command))
        let goal = try decode(GoalEnvelope.self, from: await send(request)).goal
        guard goal.id == goalID, goal.revision >= command.expectedRevision else {
            throw POSAPIError.decoding("目标命令响应与请求不匹配")
        }
        return goal
    }

    public func createGoalTask(_ session: AuthSession, goalID: String, _ request: CreateGoalTaskRequest) async throws -> GoalTask {
        try validateCommandID(request.commandId)
        let urlRequest = try authorizedRequest(method: "POST", path: goalPath(goalID) + "/tasks",
            session: session, body: encode(request))
        let task = try decode(GoalTaskEnvelope.self, from: await send(urlRequest)).task
        guard task.goalId == goalID, task.revision >= 1, isResourceID(task.id) else {
            throw POSAPIError.decoding("任务响应与目标不匹配")
        }
        return task
    }

    public func updateGoalTask(_ session: AuthSession, taskID: String, _ command: GoalTaskCommand) async throws -> GoalTask {
        try validateCommandID(command.commandId)
        guard isResourceID(taskID) else { throw POSAPIError.decoding("任务 ID 无效") }
        let request = try authorizedRequest(method: "POST", path: "v2/tasks/\(taskID)/commands",
            session: session, body: encode(command))
        let task = try decode(GoalTaskEnvelope.self, from: await send(request)).task
        guard task.id == taskID, isResourceID(task.goalId), task.revision >= command.expectedRevision else {
            throw POSAPIError.decoding("任务命令响应与请求不匹配")
        }
        return task
    }

    public func goalTask(_ session: AuthSession, taskID: String) async throws -> GoalTaskDetail {
        guard isResourceID(taskID) else { throw POSAPIError.decoding("任务 ID 无效") }
        var entries: [GoalProgressEntry] = []
        var after = 0
        var revision: Int?
        while true {
            var query = [URLQueryItem(name: "progressAfter", value: String(after)), URLQueryItem(name: "progressLimit", value: "100")]
            if let revision { query.append(URLQueryItem(name: "progressRevision", value: String(revision))) }
            let request = try authorizedRequest(method: "GET", path: "v2/tasks/\(taskID)", query: query, session: session)
            let page = try decode(GoalTaskDetail.self, from: await send(request))
            guard page.task.id == taskID, page.task.revision >= 1, isResourceID(page.task.goalId),
                  page.progressEntries.count <= 100,
                  page.progressEntries.allSatisfy({ $0.taskId == taskID }),
                  revision == nil || revision == page.task.revision else {
                throw POSAPIError.decoding("任务在读取期间已变化，请刷新进展记录")
            }
            revision = page.progressRevision ?? page.task.revision
            entries.append(contentsOf: page.progressEntries)
            guard Set(entries.map(\.id)).count == entries.count else { throw POSAPIError.decoding("进展分页记录重复") }
            if let next = page.nextCursor {
                guard next > after, !page.progressEntries.isEmpty else { throw POSAPIError.decoding("进展分页游标无效") }
                if entries.count < 2_000 { after = next; continue }
            }
            return GoalTaskDetail(task: page.task, progressEntries: entries, nextCursor: page.nextCursor, progressRevision: revision)
        }
    }

    public func askGoal(_ session: AuthSession, goalID: String, _ request: GoalQuestionRequest) async throws -> SendMessageAck {
        _ = try messagesPath(request.conversationId)
        try validateCommandID(request.clientRequestId)
        let urlRequest = try authorizedRequest(method: "POST", path: goalPath(goalID) + "/questions",
            session: session, body: encode(request))
        let ack = try decode(SendMessageAck.self, from: await send(urlRequest))
        guard ack.message.conversationID == request.conversationId,
              ack.message.clientRequestID == request.clientRequestId,
              ack.message.role == "user", ack.message.text == request.text,
              ack.run.conversationId == request.conversationId, ack.run.messageId == ack.message.id,
              ack.run.goalId == goalID else {
            throw POSAPIError.decoding("目标问答回执与原消息不匹配")
        }
        try validate(ack.run, expectedID: ack.run.id)
        return ack
    }

    public func goalContext(_ session: AuthSession, runID: String) async throws -> GoalQuestionContext? {
        let request = try authorizedRequest(method: "GET", path: runsPath(runID) + "/goal-context", session: session)
        guard let context = try decode(GoalContextEnvelope.self, from: await send(request)).goalContext else { return nil }
        guard context.runId == runID, isResourceID(context.goalId), context.goal.id == context.goalId,
              context.viewRevision >= 1,
              Set(context.includedTasks.map { $0.task.id }).count == context.includedTasks.count,
              context.includedTasks.allSatisfy({ item in
                  item.task.goalId == context.goalId && item.task.revision >= 1 &&
                      item.progressEntries.allSatisfy { $0.taskId == item.task.id }
              }) else { throw POSAPIError.decoding("回答依据与本次运行不匹配") }
        return context
    }

    private func goalPath(_ goalID: String) throws -> String {
        guard isResourceID(goalID) else { throw POSAPIError.decoding("目标 ID 无效") }
        return "v2/goals/\(goalID)"
    }

    private func isResourceID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private func validateCommandID(_ id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw POSAPIError.decoding("目标命令缺少幂等键")
        }
    }

    private func runsPath(_ runID: String) throws -> String {
        guard runID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw POSAPIError.decoding("运行 ID 无效")
        }
        return "v2/runs/\(runID)"
    }

    private func validate(_ run: Run, expectedID: String) throws {
        guard run.id == expectedID,
              run.conversationId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              run.messageId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              RunStatus(rawValue: run.status) != nil else {
            throw POSAPIError.decoding("运行响应与请求或 v2 状态不匹配")
        }
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

    private func send(_ request: URLRequest, isHealthCheck: Bool = false) async throws -> Data {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw POSAPIError.transport("响应不是 HTTP") }
            guard (200..<300).contains(http.statusCode) else {
                // v2 health 必须公开可读；旧网关在鉴权前拦截未知路由，不能误报为密钥错误。
                if isHealthCheck, [401, 403, 404].contains(http.statusCode) {
                    throw POSAPIError.server(status: http.statusCode, code: "v2_unavailable",
                        message: "当前地址未提供可用的 v2 服务。请更新云端服务并检查 /v2/* 转发，或填写 v2 服务器地址后重新配对。")
                }
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

private struct GoalContextEnvelope: Decodable { let goalContext: GoalQuestionContext? }
private struct GoalsEnvelope: Decodable { let goals: [Goal]; let nextCursor: Int? }
private struct GoalEnvelope: Decodable { let goal: Goal }
private struct GoalViewEnvelope: Decodable { let goalView: GoalDetail }
private struct GoalTaskEnvelope: Decodable { let task: GoalTask }
private struct DeviceEnvelope: Decodable { let device: DeviceInfo }
private struct ConversationEnvelope: Decodable { let conversation: Conversation }
private struct ConversationsEnvelope: Decodable { let conversations: [Conversation] }
private struct RunEnvelope: Decodable { let run: Run }
private struct CreateConversationRequest: Encodable { let title: String? }
private struct ErrorEnvelope: Decodable {
    struct Payload: Decodable { let code: String; let message: String }
    let error: Payload
}
