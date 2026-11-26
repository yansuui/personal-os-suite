import Foundation

/// 与聊天快照一起原子保存，但同步时间独立；写本地草稿不能冒充云端同步。
public struct GoalCache: Sendable, Codable, Equatable {
    public let lastSyncedAt: String?
    public let taskDetails: [GoalTaskDetail]
    public let drafts: [GoalDraft]
    public let contexts: [GoalQuestionContext]
    public init(lastSyncedAt: String? = nil, taskDetails: [GoalTaskDetail] = [],
                drafts: [GoalDraft] = [], contexts: [GoalQuestionContext] = []) {
        self.lastSyncedAt = lastSyncedAt; self.taskDetails = taskDetails
        self.drafts = drafts; self.contexts = contexts
    }
}
