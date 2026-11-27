import Foundation

/// v2 聊天与可选的目标能力；旧任务审批、上下文和 presence 仍未接入。
public protocol POSAPI: Sendable {
    func health() async throws -> HealthResponse
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession
    func me(_ session: AuthSession) async throws -> DeviceInfo
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation
    func conversations(_ session: AuthSession) async throws -> [Conversation]
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck
    func run(_ session: AuthSession, runID: String) async throws -> Run
    func cancelRun(_ session: AuthSession, runID: String) async throws -> Run
    func capabilities(_ session: AuthSession) async throws -> POSCapabilities
    func goals(_ session: AuthSession, status: GoalStatus) async throws -> [Goal]
    func goal(_ session: AuthSession, goalID: String) async throws -> GoalDetail
    func createGoal(_ session: AuthSession, _ request: CreateGoalRequest) async throws -> Goal
    func updateGoal(_ session: AuthSession, goalID: String, _ command: GoalCommand) async throws -> Goal
    func createGoalTask(_ session: AuthSession, goalID: String, _ request: CreateGoalTaskRequest) async throws -> GoalTask
    func updateGoalTask(_ session: AuthSession, taskID: String, _ command: GoalTaskCommand) async throws -> GoalTask
    func goalTask(_ session: AuthSession, taskID: String) async throws -> GoalTaskDetail
    func askGoal(_ session: AuthSession, goalID: String, _ request: GoalQuestionRequest) async throws -> SendMessageAck
    func goalContext(_ session: AuthSession, runID: String) async throws -> GoalQuestionContext?
}

/// 已有聊天实现和测试替身可继续工作；只有显式声明能力后才调用目标接口。
public extension POSAPI {
    func capabilities(_ session: AuthSession) async throws -> POSCapabilities { POSCapabilities() }
    func goals(_ session: AuthSession, status: GoalStatus) async throws -> [Goal] { throw goalsUnavailable() }
    func goal(_ session: AuthSession, goalID: String) async throws -> GoalDetail { throw goalsUnavailable() }
    func createGoal(_ session: AuthSession, _ request: CreateGoalRequest) async throws -> Goal { throw goalsUnavailable() }
    func updateGoal(_ session: AuthSession, goalID: String, _ command: GoalCommand) async throws -> Goal { throw goalsUnavailable() }
    func createGoalTask(_ session: AuthSession, goalID: String, _ request: CreateGoalTaskRequest) async throws -> GoalTask { throw goalsUnavailable() }
    func updateGoalTask(_ session: AuthSession, taskID: String, _ command: GoalTaskCommand) async throws -> GoalTask { throw goalsUnavailable() }

    func goalTask(_ session: AuthSession, taskID: String) async throws -> GoalTaskDetail { throw goalsUnavailable() }
    func askGoal(_ session: AuthSession, goalID: String, _ request: GoalQuestionRequest) async throws -> SendMessageAck { throw goalsUnavailable() }
    func goalContext(_ session: AuthSession, runID: String) async throws -> GoalQuestionContext? { throw goalsUnavailable() }

    private func goalsUnavailable() -> POSAPIError {
        .server(status: 501, code: "goals_unavailable", message: "当前服务器尚未提供目标能力")
    }
}
