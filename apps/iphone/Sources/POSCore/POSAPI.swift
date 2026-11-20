import Foundation

/// POSCore 对服务端的全部读取/写入能力。
///
/// CONTRACT §3 公开面，签名不可改。实现见 `URLSessionPOSAPI`；
/// 测试与预览可以注入自己的实现（例如 URLProtocol 桩）。
public protocol POSAPI: Sendable {
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession
    func me(_ session: AuthSession) async throws -> DeviceInfo
    func timeline(_ session: AuthSession, after: Int, waitSeconds: Int) async throws -> TimelinePage
    func sendMessage(_ session: AuthSession, _ request: SendMessageRequest) async throws -> SendMessageAck
    func tasks(_ session: AuthSession) async throws -> TaskList
    func approve(_ session: AuthSession, taskID: String, approved: Bool, note: String?) async throws
    func submitVerdict(_ session: AuthSession, taskID: String, verdict: String, note: String?) async throws
    func context(_ session: AuthSession) async throws -> ContextSnapshot
    func presence(_ session: AuthSession) async throws -> Presence
}
