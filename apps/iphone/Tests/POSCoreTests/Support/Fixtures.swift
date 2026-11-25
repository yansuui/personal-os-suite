import Foundation
import POSCore

/// 测试夹具：只用公开 Codable 面构造值对象，不依赖内部 memberwise init。
enum Fixtures {
    static let baseURL = URL(string: "http://127.0.0.1:8787")!
    static let conversationID = "conv-1"
    static let conversationJSON = #"{"id":"conv-1","ownerId":"default","title":"聊天","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}"#
    static let deviceJSON = #"{"id":"device-1","name":"iPhone","role":"client","createdAt":"2026-01-01T00:00:00.000Z","lastSeenAt":null,"revokedAt":null}"#

    static func session(token: String = "test-token") throws -> AuthSession {
        try decode(AuthSession.self, from: "{\"token\":\"\(token)\",\"device\":\(deviceJSON)}")
    }

    static func sendMessageRequest(clientRequestID: String = "req-1", text: String = "hello") throws -> SendMessageRequest {
        SendMessageRequest(clientRequestID: clientRequestID, text: text)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func message(messageID: String = "m1", seq: Int = 1, role: String = "user",
                        text: String = "hello", conversationID: String = "conv-1",
                        clientRequestID: String? = "req-1") -> String {
        let key = clientRequestID.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(messageID)","conversationId":"\(conversationID)","clientRequestId":\(key),
         "seq":\(seq),"role":"\(role)","text":"\(text)","createdAt":"2026-01-01T00:00:00.000Z"}
        """
    }

    static func messagePage(messages: [String] = [], nextCursor: Int = 0) -> String {
        "{\"messages\":[\(messages.joined(separator: ","))],\"nextCursor\":\(nextCursor)}"
    }

    static func sendAck(created: Bool = true, clientRequestID: String = "req-1") -> String {
        """
        {"message":\(message(clientRequestID: clientRequestID)),
         "run":{"id":"run-1","conversationId":"conv-1","messageId":"m1","status":"queued"},
         "created":\(created)}
        """
    }
}

/// `CredentialStore` 的内存替身：验证协议语义与可注入性（不触碰真实 Keychain）。
final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AuthSession?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() throws -> AuthSession? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ session: AuthSession) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = session
        saveCount += 1
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
        clearCount += 1
    }
}

/// 线程安全的 SyncEvent 收集器（测试里不从闭包直接改外部 var）。
final class SyncEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncEvent] = []

    func append(_ event: SyncEvent) {
        lock.lock()
        defer { lock.unlock() }
        items.append(event)
    }

    var events: [SyncEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var firstCursor: Int? {
        for event in events {
            if case .cursor(let value) = event { return value }
        }
        return nil
    }

    var firstDisconnected: POSAPIError? {
        for event in events {
            if case .disconnected(let error) = event { return error }
        }
        return nil
    }

    var connectedCount: Int {
        events.reduce(0) { count, event in
            if case .connected = event { return count + 1 }
            return count
        }
    }

    var messageIDs: [String] {
        for event in events {
            if case .messages(let messages) = event { return messages.map(\.id) }
        }
        return []
    }
}

/// `SnapshotStore` 的内存替身：可预置快照，也可记录写入。
final class MemorySnapshotStore: SnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CachedSnapshot?
    private(set) var saveCount = 0

    init(snapshot: CachedSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func loadSnapshot() throws -> CachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func saveSnapshot(_ snapshot: CachedSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
        saveCount += 1
    }
}
