import Foundation

/// 原命令与表单同一次原子快照落盘。网络结果不确定时，重启和重试复用该值。
public enum GoalMutation: Sendable, Codable, Equatable {
    case createGoal(CreateGoalRequest)
    case goal(id: String, command: GoalCommand)
    case createTask(goalID: String, request: CreateGoalTaskRequest)
    case task(id: String, goalID: String, command: GoalTaskCommand)

    public var commandID: String {
        switch self {
        case .createGoal(let request): return request.commandId
        case .goal(_, let command): return command.commandId
        case .createTask(_, let request): return request.commandId
        case .task(_, _, let command): return command.commandId
        }
    }
}

public enum GoalDraftKind: String, Sendable, Codable {
    case createGoal, editGoal, goalAction, createTask, editTask, taskStatus, taskProgress
}

public enum GoalDraftState: String, Sendable, Codable {
    case editing, sending, unconfirmed, conflict, rejected
}

public struct GoalDraft: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let kind: GoalDraftKind
    public let goalID: String?
    public let taskID: String?
    public var expectedRevision: Int?
    public var title: String
    public var description: String
    public var successCriteria: String
    public var date: String
    public var status: GoalTaskStatus?
    public var goalAction: GoalAction?
    public var note: String
    public var resultNote: String
    public var mutation: GoalMutation?
    public var state: GoalDraftState
    public var error: String?

    public init(id: String, kind: GoalDraftKind, goalID: String? = nil, taskID: String? = nil,
                expectedRevision: Int? = nil, title: String = "", description: String = "",
                successCriteria: String = "", date: String = "", status: GoalTaskStatus? = nil,
                goalAction: GoalAction? = nil, note: String = "", resultNote: String = "") {
        self.id = id; self.kind = kind; self.goalID = goalID; self.taskID = taskID
        self.expectedRevision = expectedRevision; self.title = title; self.description = description
        self.successCriteria = successCriteria; self.date = date; self.status = status
        self.goalAction = goalAction; self.note = note; self.resultNote = resultNote
        self.mutation = nil; self.state = .editing; self.error = nil
    }

    /// 不同目标动作和任务状态必须使用独立槽，不能恢复成上次关闭的另一种选择。
    public static func forGoalAction(_ goal: Goal, action: GoalAction) -> Self {
        Self(id: "goal:\(goal.id):action:\(action.rawValue)", kind: .goalAction, goalID: goal.id,
             expectedRevision: goal.revision, title: goal.title, goalAction: action)
    }

    public static func forTaskStatus(_ task: GoalTask, status: GoalTaskStatus) -> Self {
        Self(id: "task:\(task.id):status:\(status.rawValue)", kind: .taskStatus, goalID: task.goalId,
             taskID: task.id, expectedRevision: task.revision, title: task.title, status: status)
    }

    public var isLocked: Bool { mutation != nil }
    public var hasUncertainResult: Bool { state == .sending || state == .unconfirmed }
    public var isValid: Bool {
        switch kind {
        case .createGoal, .editGoal, .createTask, .editTask:
            return !clean(title).isEmpty && (clean(date).isEmpty || Self.isNaturalDate(clean(date)))
        case .taskProgress: return !clean(note).isEmpty
        case .taskStatus: return status != nil && (status != .blocked || !clean(note).isEmpty)
        case .goalAction: return goalAction != nil
        }
    }

    public func makeMutation(commandID: String = UUID().uuidString) -> GoalMutation? {
        guard isValid else { return nil }
        switch kind {
        case .createGoal:
            return .createGoal(CreateGoalRequest(commandId: commandID, title: clean(title),
                description: optional(description), successCriteria: optional(successCriteria), targetDate: optional(date)))
        case .editGoal:
            guard let goalID, let expectedRevision else { return nil }
            return .goal(id: goalID, command: GoalCommand(commandId: commandID, expectedRevision: expectedRevision,
                action: .update, title: clean(title), description: .replacing(optional(description)),
                successCriteria: .replacing(optional(successCriteria)), targetDate: .replacing(optional(date))))
        case .goalAction:
            guard let goalID, let expectedRevision, let goalAction else { return nil }
            return .goal(id: goalID, command: GoalCommand(commandId: commandID,
                expectedRevision: expectedRevision, action: goalAction))
        case .createTask:
            guard let goalID else { return nil }
            return .createTask(goalID: goalID, request: CreateGoalTaskRequest(commandId: commandID,
                title: clean(title), description: optional(description), dueDate: optional(date)))
        case .editTask:
            guard let taskID, let goalID, let expectedRevision else { return nil }
            return .task(id: taskID, goalID: goalID, command: GoalTaskCommand(commandId: commandID,
                expectedRevision: expectedRevision, action: .update, title: clean(title),
                description: .replacing(optional(description)), dueDate: .replacing(optional(date))))
        case .taskStatus, .taskProgress:
            guard let taskID, let goalID, let expectedRevision else { return nil }
            return .task(id: taskID, goalID: goalID, command: GoalTaskCommand(commandId: commandID,
                expectedRevision: expectedRevision, action: kind == .taskStatus ? .setStatus : .progress,
                status: kind == .taskStatus ? status : nil, note: optional(note),
                resultNote: kind == .taskStatus && status == .completed ? optional(resultNote) : nil))
        }
    }

    public static func isNaturalDate(_ value: String) -> Bool {
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func optional(_ text: String) -> String? { clean(text).isEmpty ? nil : clean(text) }
}
