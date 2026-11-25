import Foundation

/// 冻结 v2 最小聊天接口；任务、审批、上下文和 presence 不属于本轮协议。
public protocol POSAPI: Sendable {
    func health() async throws -> HealthResponse
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession
    func me(_ session: AuthSession) async throws -> DeviceInfo
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation
    func conversations(_ session: AuthSession) async throws -> [Conversation]
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck
}
