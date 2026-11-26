import Foundation

// MARK: - v2 身份与聊天

public struct DeviceInfo: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let role: String
    public let createdAt: String
}

/// 保持原 Keychain 的 `{token, device}` 编码结构。
public struct AuthSession: Sendable, Codable, Equatable {
    public let token: String
    public let device: DeviceInfo
}

public struct PairRequest: Sendable, Codable, Equatable {
    public let name: String
    public let role: String

    public init(name: String, role: String = "client") {
        self.name = name
        self.role = role
    }
}

public struct HealthResponse: Sendable, Codable, Equatable {
    public let ok: Bool
    public let service: String
    public let protocolVersion: Int
    public let model: String?
}

public struct Conversation: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let ownerId: String
    public let title: String?
    public let createdAt: String
    public let updatedAt: String
}

public struct ChatMessage: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    /// 只为读取升级前的本地快照允许 nil；v2 网络响应必须包含此字段。
    public let conversationID: String?
    public let clientRequestID: String?
    public let seq: Int
    public let role: String
    public let text: String
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, seq, role, text, createdAt
        case conversationID = "conversationId"
        case clientRequestID = "clientRequestId"
    }

    public init(id: String, conversationID: String? = nil, clientRequestID: String? = nil,
                seq: Int, role: String, text: String, createdAt: String) {
        self.id = id
        self.conversationID = conversationID
        self.clientRequestID = clientRequestID
        self.seq = seq
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct MessagePage: Sendable, Codable, Equatable {
    public let messages: [ChatMessage]
    public let nextCursor: Int
}

public struct SendMessageRequest: Sendable, Codable, Equatable {
    public let clientRequestID: String
    public let text: String

    private enum CodingKeys: String, CodingKey {
        case clientRequestID = "clientRequestId"
        case text
    }

    public init(clientRequestID: String, text: String) {
        self.clientRequestID = clientRequestID
        self.text = text
    }
}

/// client 只读取运行状态；不会领取/完成 agent 的运行。
public struct Run: Sendable, Codable, Equatable {
    public let id: String
    public let conversationId: String
    public let messageId: String
    public let status: String
    public let error: String?
    public let goalId: String?
}

public enum RunStatus: String, Sendable, Codable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case canceled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled: return true
        case .queued, .running: return false
        }
    }

    public var title: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "生成中"
        case .completed: return "已完成"
        case .failed: return "运行失败"
        case .canceled: return "已取消"
        }
    }
}

/// 只持久化 client 展示与恢复需要的字段，不包含 agent lease 信息。
public struct RunRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: String { runID }
    public let runID: String
    public let conversationID: String
    public let messageID: String
    public var status: RunStatus
    public var serverError: String?
    public var pollingError: String?
    public var cancellationError: String?
    public var goalID: String?

    public init(runID: String, conversationID: String, messageID: String, status: RunStatus,
                serverError: String? = nil, pollingError: String? = nil, cancellationError: String? = nil,
                goalID: String? = nil) {
        self.runID = runID
        self.conversationID = conversationID
        self.messageID = messageID
        self.status = status
        self.serverError = serverError
        self.pollingError = pollingError
        self.cancellationError = cancellationError
        self.goalID = goalID
    }
}

public struct SendMessageAck: Sendable, Codable, Equatable {
    public let message: ChatMessage
    public let run: Run
    public let created: Bool
}

/// 网络发送前落盘；自动重试、手动重试、重启后重试都复用这里的键。
public struct PendingMessage: Sendable, Codable, Equatable, Identifiable {
    public var id: String { clientRequestID }
    public let conversationID: String
    public let clientRequestID: String
    public let text: String
    public let createdAt: String
    /// nil 同时兼容升级前的普通待发消息；重试时绝不读取当前关联替代它。
    public let goalID: String?

    public init(conversationID: String, clientRequestID: String = UUID().uuidString,
                text: String, createdAt: String, goalID: String? = nil) {
        self.conversationID = conversationID
        self.clientRequestID = clientRequestID
        self.text = text
        self.createdAt = createdAt
        self.goalID = goalID
    }

    public var request: SendMessageRequest {
        SendMessageRequest(clientRequestID: clientRequestID, text: text)
    }
}

public struct ConversationSnapshot: Sendable, Codable, Equatable {
    public let conversationID: String
    public let messages: [ChatMessage]
    public let cursor: Int

    public init(conversationID: String, messages: [ChatMessage], cursor: Int) {
        self.conversationID = conversationID
        self.messages = messages
        self.cursor = cursor
    }
}

// MARK: - 升级前本地快照类型（不代表 v2 已提供这些能力）

public struct TaskSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let updatedAt: String
    public let requiresApproval: Bool
    public let approvedAt: String?
    public let verdict: String?
    public let outputTail: String?
    public let errorText: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, status, updatedAt, requiresApproval, approvedAt, verdict, outputTail
        case errorText = "error"
    }
}

public struct PlanItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let planDate: String
    public let title: String
    public let owner: String
    public let startTime: String?
    public let endTime: String?
    public let minutes: Int?
    public let status: String
    public let progress: Int
}

public struct MemoryHit: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let content: String
    public let kind: String
    public let tags: [String]
    public let scope: String
    public let importance: Int
    public let updatedAt: String
}

public struct ContextSnapshot: Sendable, Codable, Equatable {
    public let available: Bool
    public let plan: [PlanItem]
    public let memory: [MemoryHit]
    public let asOf: String?
}

public struct Presence: Sendable, Codable, Equatable {
    public let desktopOnline: Bool
    public let cloudAgentOnline: Bool
    public let queuedChat: Int
}

// MARK: - 本地缓存

/// 保留旧字段以读取旧快照；v2 会话数据与游标独立保存，绝不沿用全局旧游标。
public struct CachedSnapshot: Sendable, Codable, Equatable {
    public let savedAt: String
    public let timeline: [ChatMessage]
    public let cursor: Int
    public let tasks: [TaskSummary]
    public let context: ContextSnapshot?
    public let conversations: [Conversation]
    public let selectedConversationID: String?
    public let conversationStates: [ConversationSnapshot]
    public let pendingMessages: [PendingMessage]
    public let runRecords: [RunRecord]
    public let goals: [Goal]
    public let goalDetails: [GoalDetail]
    /// 本机会话选择；实际发送意图在 PendingMessage.goalID 中冻结。
    public let conversationGoalIDs: [String: String]
    public let identityKey: String?
    public let goalCache: GoalCache

    private enum CodingKeys: String, CodingKey {
        case savedAt, timeline, cursor, tasks, context
        case conversations, selectedConversationID, conversationStates, pendingMessages, runRecords
        case goals, goalDetails, conversationGoalIDs, identityKey, goalCache
    }

    public init(savedAt: String, timeline: [ChatMessage] = [], cursor: Int = 0,
                tasks: [TaskSummary] = [], context: ContextSnapshot? = nil,
                conversations: [Conversation] = [], selectedConversationID: String? = nil,
                conversationStates: [ConversationSnapshot] = [], pendingMessages: [PendingMessage] = [],
                runRecords: [RunRecord] = [], goals: [Goal] = [], goalDetails: [GoalDetail] = [],
                conversationGoalIDs: [String: String] = [:], identityKey: String? = nil, goalCache: GoalCache = GoalCache()) {
        self.savedAt = savedAt
        self.timeline = timeline
        self.cursor = cursor
        self.tasks = tasks
        self.context = context
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.conversationStates = conversationStates
        self.pendingMessages = pendingMessages
        self.runRecords = runRecords
        self.goals = goals
        self.goalDetails = goalDetails
        self.conversationGoalIDs = conversationGoalIDs
        self.identityKey = identityKey
        self.goalCache = goalCache
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = try values.decode(String.self, forKey: .savedAt)
        timeline = try values.decodeIfPresent([ChatMessage].self, forKey: .timeline) ?? []
        cursor = try values.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
        tasks = try values.decodeIfPresent([TaskSummary].self, forKey: .tasks) ?? []
        context = try values.decodeIfPresent(ContextSnapshot.self, forKey: .context)
        conversations = try values.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        selectedConversationID = try values.decodeIfPresent(String.self, forKey: .selectedConversationID)
        conversationStates = try values.decodeIfPresent([ConversationSnapshot].self, forKey: .conversationStates) ?? []
        pendingMessages = try values.decodeIfPresent([PendingMessage].self, forKey: .pendingMessages) ?? []
        runRecords = try values.decodeIfPresent([RunRecord].self, forKey: .runRecords) ?? []
        goals = try values.decodeIfPresent([Goal].self, forKey: .goals) ?? []
        goalDetails = try values.decodeIfPresent([GoalDetail].self, forKey: .goalDetails) ?? []
        conversationGoalIDs = try values.decodeIfPresent([String: String].self, forKey: .conversationGoalIDs) ?? [:]
        identityKey = try values.decodeIfPresent(String.self, forKey: .identityKey)
        goalCache = try values.decodeIfPresent(GoalCache.self, forKey: .goalCache) ?? GoalCache()
    }
}
