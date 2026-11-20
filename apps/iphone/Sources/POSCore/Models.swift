import Foundation

// MARK: - 身份

/// 已配对设备。字段与 `/v1/pair`、`/v1/me` 返回的 `device` 对齐（服务端另有
/// `controller` / `capabilities` / `lastSeenAt` 等字段，这里只取 UI 需要的部分）。
public struct DeviceInfo: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let role: String        // "client" | "worker"
    public let kind: String?       // "desktop" | "cloud-agent" | nil
    public let createdAt: String
}

/// `/v1/pair` 的返回体 `{ device, token }`。
public struct AuthSession: Sendable, Codable, Equatable {
    public let token: String
    public let device: DeviceInfo
}

/// `POST /v1/pair` 的请求体。服务端读取 `name` / `role` / `kind` / `capabilities`。
public struct PairRequest: Sendable, Codable, Equatable {
    public var name: String
    public var role: String        // 手机固定 "client"
    public var kind: String?       // 手机固定 nil
    public var capabilities: [String]

    // CONTRACT-DEVIATION: CONTRACT §3 未列出 init，但 C 需要在 pair() 中构造请求，
    // 因此补一个纯加法式公开初始化器（属性名、标签、可选性均未改动）。
    public init(name: String, role: String = "client", kind: String? = nil, capabilities: [String] = []) {
        self.name = name
        self.role = role
        self.kind = kind
        self.capabilities = capabilities
    }
}

// MARK: - 会话与时间线

/// 一条时间线消息。
///
/// 服务端有两个来源，字段名不同，这里用 `CodingKeys` 统一：
/// - `/v1/timeline/events`：`messageId` / `eventCursor` / `source`；
/// - `/v1/chat/messages`：`id` / `seq` / `role`。
/// CONTRACT-DEVIATION: CONTRACT §3 的 ChatMessage 字段名与服务端 timeline 事件不一致，
/// 故 `init(from:)` 同时接受两套键（id←messageId、seq←eventCursor、role←source 派生）。
public struct ChatMessage: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let seq: Int
    public let role: String        // "user" | "assistant" | "system"
    public let text: String
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId
        case seq
        case eventCursor
        case role
        case source
        case text
        case createdAt
    }

    // CONTRACT-DEVIATION: CONTRACT §3 未列出 init，但 C 需要构造乐观插入的本地消息，
    // 故补一个纯加法式公开初始化器（参数名/顺序与 §3 属性列表一致）。
    public init(id: String, seq: Int, role: String, text: String, createdAt: String) {
        self.id = id
        self.seq = seq
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .id) {
            id = value
        } else if let value = try container.decodeIfPresent(String.self, forKey: .messageId) {
            id = value
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "消息缺少 id / messageId"
            )
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: .seq) {
            seq = value
        } else if let value = try container.decodeIfPresent(Int.self, forKey: .eventCursor) {
            seq = value
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .seq,
                in: container,
                debugDescription: "消息缺少 seq / eventCursor"
            )
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .role) {
            role = value
        } else if let value = try container.decodeIfPresent(String.self, forKey: .source) {
            // timeline payload 没有 role，只有 source：phone/desktop 视为用户，assistant 视为助手。
            role = value == "assistant" ? "assistant" : "user"
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .role,
                in: container,
                debugDescription: "消息缺少 role / source"
            )
        }
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(seq, forKey: .seq)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// `/v1/timeline/events` 的一页：`{ timelineId, events, nextCursor, previousCursor }`。
/// `nextCursor` 只在服务端「还有更多事件」时非空；空页保持旧游标由调用方（SyncEngine）负责。
public struct TimelinePage: Sendable, Codable, Equatable {
    public let events: [ChatMessage]
    public let nextCursor: Int?
}

/// `POST /v1/chat/messages` 的请求体。`clientRequestID` 是幂等键，重试必须复用同一个值。
public struct SendMessageRequest: Sendable, Codable, Equatable {
    public var clientRequestID: String   // 幂等键，重试必须复用
    public var text: String
    public var conversationID: String?

    private enum CodingKeys: String, CodingKey {
        case clientRequestID = "clientRequestId"
        case text
        case conversationID = "conversationId"
    }

    // CONTRACT-DEVIATION: CONTRACT §3 未列出 init，但 C 必须生成并持有幂等键，
    // 故补一个纯加法式公开初始化器。
    public init(clientRequestID: String, text: String, conversationID: String? = nil) {
        self.clientRequestID = clientRequestID
        self.text = text
        self.conversationID = conversationID
    }
}

/// `POST /v1/chat/messages` 的确认。
///
/// CONTRACT-DEVIATION: 服务端当前返回 `{ message: { id, ... }, duplicate: Bool }`，
/// 没有 `messageID` / `runID` 字段；URLSessionPOSAPI 会把 `message.id` 映射成
/// `messageID`，`runID` 留空（本轮服务端不产生运行回合 id）。
public struct SendMessageAck: Sendable, Codable, Equatable {
    public let messageID: String
    public let runID: String?
}

// MARK: - 任务 / 审批 / 验收

/// `/v1/tasks` 列表项。服务端读取字段为 `error`，契约字段名为 `errorText`，用 CodingKeys 对齐。
public struct TaskSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String      // queued|running|waiting-device|waiting-approval|completed|failed|canceled|unknown
    public let updatedAt: String
    public let requiresApproval: Bool
    public let approvedAt: String?
    public let verdict: String?    // "accepted" | "rejected" | nil
    public let outputTail: String?
    public let errorText: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case updatedAt
        case requiresApproval
        case approvedAt
        case verdict
        case outputTail
        case errorText = "error"
    }
}

/// `/v1/tasks` 的返回体。
///
/// CONTRACT-DEVIATION: 服务端只返回 `{ tasks }`，没有 `counts` 字段；`init(from:)`
/// 在缺失时退化为空字典，保持契约的非可选 `counts` 属性可解码。
public struct TaskList: Sendable, Codable, Equatable {
    public let tasks: [TaskSummary]
    public let counts: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case tasks
        case counts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([TaskSummary].self, forKey: .tasks) ?? []
        counts = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
    }
}

// MARK: - 只读上下文

/// 计划项。字段与 dsh-personal-workbench 只读服务 `PlanItem` 对齐（其余字段忽略）。
public struct PlanItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let planDate: String
    public let title: String
    public let owner: String       // "me" | "ai"
    public let startTime: String?
    public let endTime: String?
    public let minutes: Int?
    public let status: String      // "todo" | "done" | "skipped"
    public let progress: Int
}

/// 记忆命中项。字段与 dsh-agent-memory 只读服务 `MemoryHit` 对齐（其余字段忽略）。
public struct MemoryHit: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let content: String
    public let kind: String
    public let tags: [String]
    public let scope: String
    public let importance: Int
    public let updatedAt: String
}

/// 只读上下文快照（计划 + 记忆）。
///
/// CONTRACT-DEVIATION: 服务端 `GET /v1/context` 返回的是 `{ snapshots: [...] }` 的
/// 「每个 kind 一条」列表（payload 内是各 kind 自己的结构），契约声明的是扁平
/// `{ available, plan, memory, asOf }`；`init(from:)` 负责把 plan / memory 两个
/// kind 的 payload 摊平，`encode(to:)` 只写契约字段，便于本地缓存往返。
public struct ContextSnapshot: Sendable, Codable, Equatable {
    public let available: Bool
    public let plan: [PlanItem]
    public let memory: [MemoryHit]
    public let asOf: String?

    private enum CodingKeys: String, CodingKey {
        case available
        case plan
        case memory
        case asOf
        case snapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.snapshots) {
            let entries = try container.decodeIfPresent([ContextSnapshotEntry].self, forKey: .snapshots) ?? []
            let planEntry = entries.first { $0.kind == "plan" }
            let memoryEntry = entries.first { $0.kind == "memory" }
            plan = planEntry?.payload?.items ?? []
            memory = memoryEntry?.payload?.hits ?? []
            available = (planEntry?.payload?.available ?? false) || (memoryEntry?.payload?.available ?? false)
            asOf = planEntry?.asOf ?? memoryEntry?.asOf
        } else {
            available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
            plan = try container.decodeIfPresent([PlanItem].self, forKey: .plan) ?? []
            memory = try container.decodeIfPresent([MemoryHit].self, forKey: .memory) ?? []
            asOf = try container.decodeIfPresent(String.self, forKey: .asOf)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(plan, forKey: .plan)
        try container.encode(memory, forKey: .memory)
        try container.encodeIfPresent(asOf, forKey: .asOf)
    }
}

/// `/v1/context` 的单个 kind 条目（服务端还有 version/hash/source/stale/updatedAt）。
/// 只解码这里用得到的三个键；payload 结构按 kind 不同。
private struct ContextSnapshotEntry: Decodable {
    struct Payload: Decodable {
        let available: Bool?
        let items: [PlanItem]?
        let hits: [MemoryHit]?
    }

    let kind: String
    let asOf: String?
    let payload: Payload?
}

// MARK: - 在线状态

/// `/v1/presence`：服务端另有 `queuedTasks` / `checkedAt`，此处只保留契约字段。
public struct Presence: Sendable, Codable, Equatable {
    public let desktopOnline: Bool
    public let cloudAgentOnline: Bool
    public let queuedChat: Int
}

// MARK: - 本地缓存

/// 本地快照（离线首屏）。字段为契约原文。
public struct CachedSnapshot: Sendable, Codable, Equatable {
    public let savedAt: String
    public let timeline: [ChatMessage]
    public let cursor: Int
    public let tasks: [TaskSummary]
    public let context: ContextSnapshot?

    // CONTRACT-DEVIATION: CONTRACT §3 未列出 init，但 C 需要构造缓存写入 SnapshotStore，
    // 故补一个纯加法式公开初始化器。
    public init(
        savedAt: String,
        timeline: [ChatMessage],
        cursor: Int,
        tasks: [TaskSummary],
        context: ContextSnapshot? = nil
    ) {
        self.savedAt = savedAt
        self.timeline = timeline
        self.cursor = cursor
        self.tasks = tasks
        self.context = context
    }
}
