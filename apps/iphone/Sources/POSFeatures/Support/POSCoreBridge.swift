import Foundation
import POSCore

/// POSCore 值的集中适配层。
///
/// 界面层只依赖 CONTRACT §3 的公开面；所有「构造 POSCore 值」的代码都收在这里，
/// 这样一旦 POSCore 的实际签名与契约有出入，只需改本文件。
///
/// CONTRACT-GAP（需要 B 侧确认）：
/// CONTRACT §3 的 `PairRequest` / `SendMessageRequest` / `ChatMessage` / `CachedSnapshot`
/// 只声明了 `public var` / `public let` 属性，没有列出 `public init`。Swift 里公开结构体的
/// 隐式成员初始化器是 internal，跨模块不可调用。界面层必须能构造这四种值
/// （配对请求、发消息请求、乐观插入的本地消息、持久化快照），因此这里按属性声明顺序
/// 使用成员初始化器，并假定 POSCore 会补 `public init(...)`（签名逐字对应 §3 的属性列表）。
/// 若 B 侧没有补，编译会只在本文件报错，页面代码无需改动。
enum POSCoreBridge {

    // MARK: - 请求构造

    /// 手机固定 role=client、kind=nil；能力位留空（服务端要求 kebab-case 且 ≤8 项）。
    static func pairRequest(name: String, role: String) -> PairRequest {
        PairRequest(name: name, role: role, kind: nil, capabilities: [])
    }

    static func sendRequest(clientRequestID: String, text: String) -> SendMessageRequest {
        SendMessageRequest(clientRequestID: clientRequestID, text: text, conversationID: nil)
    }

    // MARK: - 消息

    /// 乐观插入的本地用户消息。id 带 `local-` 前缀，收到服务端 ack 后改写为真实 id。
    static func outgoingMessage(id: String, seq: Int, text: String) -> ChatMessage {
        message(id: id, seq: seq, role: "user", text: text, createdAt: POSDate.isoString(Date()))
    }

    static func message(id: String, seq: Int, role: String, text: String, createdAt: String) -> ChatMessage {
        ChatMessage(id: id, seq: seq, role: role, text: text, createdAt: createdAt)
    }

    /// 消息排序：seq 升序，同 seq 用 id 兜底保证稳定。
    static func messageOrder(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.seq != rhs.seq {
            return lhs.seq < rhs.seq
        }
        return lhs.id < rhs.id
    }

    /// 任务排序：更新时间倒序。
    static func taskOrder(_ lhs: TaskSummary, _ rhs: TaskSummary) -> Bool {
        let left = POSDate.parse(lhs.updatedAt) ?? Date.distantPast
        let right = POSDate.parse(rhs.updatedAt) ?? Date.distantPast
        if left != right {
            return left > right
        }
        return lhs.id < rhs.id
    }

    /// 记忆排序：重要性高者在前，其次更新时间倒序。
    static func memoryOrder(_ lhs: MemoryHit, _ rhs: MemoryHit) -> Bool {
        if lhs.importance != rhs.importance {
            return lhs.importance > rhs.importance
        }
        let left = POSDate.parse(lhs.updatedAt) ?? Date.distantPast
        let right = POSDate.parse(rhs.updatedAt) ?? Date.distantPast
        if left != right {
            return left > right
        }
        return lhs.id < rhs.id
    }

    // MARK: - 离线快照

    static func cachedSnapshot(savedAt: String,
                               timeline: [ChatMessage],
                               cursor: Int,
                               tasks: [TaskSummary],
                               context: ContextSnapshot?) -> CachedSnapshot {
        CachedSnapshot(savedAt: savedAt, timeline: timeline, cursor: cursor, tasks: tasks, context: context)
    }

    /// 稳定摘要（FNV-1a 64），用于把「服务器 + 设备 id」映射成固定目录名。
    /// 不能用 `Hashable.hashValue`：进程间不稳定，重启后会指向另一个目录。
    static func stableDigest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    // MARK: - 错误

    /// 把任意 Error 归一成契约错误，保证界面文案分支稳定。
    static func apiError(from error: Error) -> POSAPIError {
        if let apiError = error as? POSAPIError {
            return apiError
        }
        return .transport(error.localizedDescription)
    }

    /// 并行请求的统一包装：失败只带 POSAPIError，便于把三方结果合并成一个失败摘要。
    static func attempt<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, POSAPIError> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(apiError(from: error))
        }
    }

    /// 错误的可展示文案（不含 token 等敏感内容）。
    static func message(for error: POSAPIError) -> String {
        switch error {
        case .transport(let detail):
            return "网络不可达：\(detail)"
        case .unauthorized:
            return "登录已失效，请重新配对"
        case .conflict(let detail):
            return "服务端数据已更新（\(detail)）"
        case .server(let status, let code, let message):
            if message.isEmpty {
                return "服务器返回 \(status)\(code.isEmpty ? "" : "（\(code)）")"
            }
            return "服务器返回 \(status)：\(message)"
        case .decoding(let detail):
            return "响应解析失败：\(detail)"
        @unknown default:
            // POSCore 是独立模块，错误枚举非冻结：未知分支给通用文案，不崩溃。
            return "未知错误"
        }
    }

    /// 配对失败的文案：401 明确指向「配对密钥错误」。
    static func pairFailureMessage(error: Error) -> String {
        let failure = apiError(from: error)
        switch failure {
        case .unauthorized:
            return "配对密钥错误，请检查桌面端显示的密钥后重试"
        case .transport(let detail):
            return "连不上服务器：\(detail)。请确认地址、端口和局域网可达"
        case .server(let status, let code, let message) where status == 401 || status == 403:
            let detail = message.isEmpty ? "" : "：\(message)"
            return "配对密钥错误（\(status)\(code.isEmpty ? "" : " \(code)")）\(detail)"
        case .decoding(let detail):
            return "服务器响应无法解析：\(detail)"
        default:
            return message(for: failure)
        }
    }
}
