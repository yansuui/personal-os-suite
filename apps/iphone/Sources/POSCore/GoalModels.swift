import Foundation

// MARK: - v2 目标与目标内任务（独立于旧 TaskSummary）

public struct POSCapabilities: Sendable, Codable, Equatable {
    public let goalsTasksVersion: Int?
    public let goalQuestionsVersion: Int?

    public init(goalsTasksVersion: Int? = nil, goalQuestionsVersion: Int? = nil) {
        self.goalsTasksVersion = goalsTasksVersion
        self.goalQuestionsVersion = goalQuestionsVersion
    }

    public var supportsGoals: Bool { (goalsTasksVersion ?? 0) >= 1 }
    public var supportsGoalQuestions: Bool { supportsGoals && (goalQuestionsVersion ?? 0) >= 1 }
}

public enum GoalStatus: String, Sendable, Codable, CaseIterable, Identifiable {
    case active, completed, archived
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .active: return "进行中"
        case .completed: return "已完成"
        case .archived: return "已归档"
        }
    }
}

public enum GoalTaskStatus: String, Sendable, Codable, CaseIterable, Identifiable {
    case todo
    case inProgress = "in_progress"
    case blocked, completed, canceled
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .todo: return "待做"
        case .inProgress: return "进行中"
        case .blocked: return "受阻"
        case .completed: return "已完成"
        case .canceled: return "已取消"
        }
    }
    public var isTerminal: Bool { self == .completed || self == .canceled }
    public var nextStatuses: [Self] {
        isTerminal ? [.todo] : Self.allCases.filter { $0 != self }
    }
}

public struct Goal: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let ownerId: String?
    public let title: String
    public let description: String?
    public let successCriteria: String?
    public let targetDate: String?
    public let status: GoalStatus
    public let archivedFromStatus: GoalStatus?
    public let revision: Int
    public let createdAt: String
    public let updatedAt: String
    /// 仅列表视图附带；创建与命令回执返回基础 Goal。
    public let summary: GoalTaskSummary?
    public let viewRevision: Int?
}

public struct GoalTask: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let goalId: String
    public let ownerId: String?
    public let title: String
    public let description: String?
    public let dueDate: String?
    public let status: GoalTaskStatus
    public let blockedReason: String?
    public let resultNote: String?
    public let revision: Int
    public let createdAt: String
    public let updatedAt: String
}

public struct GoalTaskSummary: Sendable, Codable, Equatable {
    public let completedTasks: Int
    public let todoTasks: Int?
    public let inProgressTasks: Int?
    /// 云端字段表示未取消总数，包含已完成任务。
    public let activeTasks: Int
    public let blockedTasks: Int
    public let canceledTasks: Int
    public let completionPercent: Int?
    public let latestUpdatedAt: String?
}

public struct GoalDetail: Sendable, Codable, Equatable, Identifiable {
    public var id: String { goal.id }
    public let goal: Goal
    public let tasks: [GoalTask]
    public let summary: GoalTaskSummary
    public let viewRevision: Int
    public let asOf: String
}

public enum GoalProgressKind: String, Sendable, Codable { case status, note, result }

public struct GoalProgressEntry: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let taskId: String
    public let actorDeviceId: String
    public let kind: GoalProgressKind
    public let note: String?
    public let fromStatus: GoalTaskStatus?
    public let toStatus: GoalTaskStatus?
    public let createdAt: String
}

public struct GoalTaskDetail: Sendable, Codable, Equatable, Identifiable {
    public var id: String { task.id }
    public let task: GoalTask
    public let progressEntries: [GoalProgressEntry]
    /// 非 nil 表示达到本机 2000 条历史上限，界面必须明确提示并非全量。
    public let nextCursor: Int?
    public let progressRevision: Int?
}

public struct GoalQuestionTask: Sendable, Codable, Equatable {
    public let task: GoalTask
    public let progressEntries: [GoalProgressEntry]
}

/// 只能从本次 run 的 goal-context 端点读取，不能用最新 GoalDetail 替代。
public struct GoalQuestionContext: Sendable, Codable, Equatable, Identifiable {
    public var id: String { runId }
    public let runId: String
    public let goalId: String
    public let goal: Goal
    public let viewRevision: Int
    public let asOf: String
    public let summary: GoalTaskSummary
    public let includedTasks: [GoalQuestionTask]
    public let omissions: GoalContextOmissions
}

public struct GoalContextOmissions: Sendable, Codable, Equatable {
    public let taskCount: Int
    public let progressEntryCount: Int
    public let truncatedFields: [String]
    public let reasons: [String]
}

public struct GoalQuestionRequest: Sendable, Codable, Equatable {
    public let conversationId: String
    public let clientRequestId: String
    public let text: String
    public init(conversationID: String, clientRequestID: String, text: String) {
        self.conversationId = conversationID
        self.clientRequestId = clientRequestID
        self.text = text
    }
}

/// 更新中的三态字段：省略保持原值，null 清空，value 写入新值。
public enum NullableText: Sendable, Equatable {
    case unchanged, null, value(String)
    public static func replacing(_ text: String?) -> Self { text.map(Self.value) ?? .null }

    fileprivate static func decode<K: CodingKey>(_ key: K, from values: KeyedDecodingContainer<K>) throws -> Self {
        guard values.contains(key) else { return .unchanged }
        if try values.decodeNil(forKey: key) { return .null }
        return .value(try values.decode(String.self, forKey: key))
    }
    fileprivate func encode<K: CodingKey>(_ key: K, to values: inout KeyedEncodingContainer<K>) throws {
        switch self {
        case .unchanged: break
        case .null: try values.encodeNil(forKey: key)
        case .value(let text): try values.encode(text, forKey: key)
        }
    }
}

public struct CreateGoalRequest: Sendable, Codable, Equatable {
    public let commandId: String
    public let title: String
    public let description: String?
    public let successCriteria: String?
    public let targetDate: String?
    public init(commandId: String = UUID().uuidString, title: String, description: String? = nil,
                successCriteria: String? = nil, targetDate: String? = nil) {
        self.commandId = commandId; self.title = title; self.description = description
        self.successCriteria = successCriteria; self.targetDate = targetDate
    }
}

public enum GoalAction: String, Sendable, Codable { case update, complete, archive, restore, reopen }

public struct GoalCommand: Sendable, Codable, Equatable {
    public let commandId: String
    public let expectedRevision: Int
    public let action: GoalAction
    public let title: String?
    public let description: NullableText
    public let successCriteria: NullableText
    public let targetDate: NullableText
    private enum CodingKeys: String, CodingKey {
        case commandId, expectedRevision, action, title, description, successCriteria, targetDate
    }
    public init(commandId: String = UUID().uuidString, expectedRevision: Int, action: GoalAction,
                title: String? = nil, description: NullableText = .unchanged,
                successCriteria: NullableText = .unchanged, targetDate: NullableText = .unchanged) {
        self.commandId = commandId; self.expectedRevision = expectedRevision; self.action = action
        self.title = title; self.description = description; self.successCriteria = successCriteria; self.targetDate = targetDate
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try values.decode(String.self, forKey: .commandId)
        expectedRevision = try values.decode(Int.self, forKey: .expectedRevision)
        action = try values.decode(GoalAction.self, forKey: .action)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        description = try NullableText.decode(.description, from: values)
        successCriteria = try NullableText.decode(.successCriteria, from: values)
        targetDate = try NullableText.decode(.targetDate, from: values)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(commandId, forKey: .commandId)
        try values.encode(expectedRevision, forKey: .expectedRevision)
        try values.encode(action, forKey: .action)
        if action == .update {
            try values.encodeIfPresent(title, forKey: .title)
            try description.encode(.description, to: &values)
            try successCriteria.encode(.successCriteria, to: &values)
            try targetDate.encode(.targetDate, to: &values)
        }
    }
}

public struct CreateGoalTaskRequest: Sendable, Codable, Equatable {
    public let commandId: String
    public let title: String
    public let description: String?
    public let dueDate: String?
    public init(commandId: String = UUID().uuidString, title: String, description: String? = nil, dueDate: String? = nil) {
        self.commandId = commandId; self.title = title; self.description = description; self.dueDate = dueDate
    }
}

public enum GoalTaskAction: String, Sendable, Codable {
    case update, progress
    case setStatus = "set_status"
}

public struct GoalTaskCommand: Sendable, Codable, Equatable {
    public let commandId: String
    public let expectedRevision: Int
    public let action: GoalTaskAction
    public let title: String?
    public let description: NullableText
    public let dueDate: NullableText
    public let status: GoalTaskStatus?
    /// blocked 的原因同样通过 note 发送，不能编码 blockedReason。
    public let note: String?
    public let resultNote: String?
    private enum CodingKeys: String, CodingKey {
        case commandId, expectedRevision, action, title, description, dueDate, status, note, resultNote
    }
    public init(commandId: String = UUID().uuidString, expectedRevision: Int, action: GoalTaskAction,
                title: String? = nil, description: NullableText = .unchanged, dueDate: NullableText = .unchanged,
                status: GoalTaskStatus? = nil, note: String? = nil, resultNote: String? = nil) {
        self.commandId = commandId; self.expectedRevision = expectedRevision; self.action = action
        self.title = title; self.description = description; self.dueDate = dueDate
        self.status = status; self.note = note; self.resultNote = resultNote
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try values.decode(String.self, forKey: .commandId)
        expectedRevision = try values.decode(Int.self, forKey: .expectedRevision)
        action = try values.decode(GoalTaskAction.self, forKey: .action)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        description = try NullableText.decode(.description, from: values)
        dueDate = try NullableText.decode(.dueDate, from: values)
        status = try values.decodeIfPresent(GoalTaskStatus.self, forKey: .status)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        resultNote = try values.decodeIfPresent(String.self, forKey: .resultNote)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(commandId, forKey: .commandId)
        try values.encode(expectedRevision, forKey: .expectedRevision)
        try values.encode(action, forKey: .action)
        switch action {
        case .update:
            try values.encodeIfPresent(title, forKey: .title)
            try description.encode(.description, to: &values)
            try dueDate.encode(.dueDate, to: &values)
        case .progress: try values.encodeIfPresent(note, forKey: .note)
        case .setStatus:
            try values.encodeIfPresent(status, forKey: .status)
            try values.encodeIfPresent(note, forKey: .note)
            try values.encodeIfPresent(resultNote, forKey: .resultNote)
        }
    }
}
