import Foundation
import XCTest
import POSCore
import POSFeatures

final class AppModelPendingMessageTests: XCTestCase {
    @MainActor
    func testNewSendUsesNewKeyForSameTextAfterUnconfirmedSend() async throws {
        let api = try PendingMessageAPI(sendFailures: [.transport("ack lost"), .transport("ack lost")])
        let (model, _) = try await makeModel(api: api)
        defer { model.signOut() }

        await model.send("继续")
        let firstPending = try XCTUnwrap(model.pendingMessages.first)
        XCTAssertEqual(model.pendingMessages.count, 1)

        // 普通发送是第二次用户意图，即使上一条同正文尚未确认也必须有新键。
        await model.send("继续")
        let sends = await api.recordedSends()
        XCTAssertEqual(sends.count, 3)
        guard sends.count == 3 else { return }
        XCTAssertEqual(sends[0].request, sends[1].request, "同一次自动重试复用原请求")
        XCTAssertEqual(sends[0].request.clientRequestID, firstPending.clientRequestID)
        XCTAssertNotEqual(sends[2].request.clientRequestID, firstPending.clientRequestID)
        XCTAssertEqual(sends[2].request.text, firstPending.text)
        XCTAssertEqual(model.pendingMessages, [firstPending], "第二条的 ack 不能清掉第一条待发项")
        XCTAssertEqual(model.messages.last?.clientRequestID, sends[2].request.clientRequestID)
    }

    @MainActor
    func testRestoredPendingKeepsKeyAndBodyForAutomaticAndExplicitRetry() async throws {
        let pending = PendingMessage(conversationID: PendingValues.conversationID,
            clientRequestID: "restored-request", text: "重试原消息", createdAt: "2026-01-01T00:00:00Z")
        let otherConversation = PendingMessage(conversationID: "other-conversation",
            clientRequestID: pending.clientRequestID, text: "其它会话的待发消息", createdAt: "now")
        let api = try PendingMessageAPI(sendFailures: [.transport("ack lost"), .transport("ack lost")])
        let (model, store) = try await makeModel(api: api, pending: [pending, otherConversation])
        defer { model.signOut() }
        let restored = try XCTUnwrap(model.pendingMessages.first)

        await model.retryPending(restored)
        XCTAssertEqual(model.pendingMessages, [pending, otherConversation])
        let afterFailure = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(afterFailure.pendingMessages, [pending, otherConversation])
        await model.retryPending(restored)

        let sends = await api.recordedSends()
        XCTAssertEqual(sends.count, 3)
        XCTAssertTrue(sends.allSatisfy {
            $0.conversationID == pending.conversationID && $0.request == pending.request
        })
        XCTAssertEqual(model.pendingMessages, [otherConversation])
        let afterAck = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(afterAck.pendingMessages, [otherConversation], "ack 不能清掉其它会话的同键待发项")
    }

    @MainActor
    func testPolledUserMessageConfirmsOnlyMatchingConversationAndRequestKey() async throws {
        let conversationID = PendingValues.conversationID
        let confirmed = PendingMessage(conversationID: conversationID, clientRequestID: "confirmed", text: "继续", createdAt: "now")
        let otherKey = PendingMessage(conversationID: conversationID, clientRequestID: "other-key", text: "继续", createdAt: "now")
        let otherConversation = PendingMessage(conversationID: "other-conversation", clientRequestID: "confirmed", text: "继续", createdAt: "now")
        let assistantOnly = PendingMessage(conversationID: conversationID, clientRequestID: "assistant-key", text: "继续", createdAt: "now")
        let systemOnly = PendingMessage(conversationID: conversationID, clientRequestID: "system-key", text: "继续", createdAt: "now")
        let pending = [confirmed, otherKey, otherConversation, assistantOnly, systemOnly]
        let api = try PendingMessageAPI()
        let (model, store) = try await makeModel(api: api, pending: pending)
        defer { model.signOut() }
        XCTAssertEqual(model.pendingMessages, pending)

        // 模拟 POST 确认丢失后，增量刷新从服务器读到了已提交的 user 消息。
        await api.setMessages([
            ChatMessage(id: "server-user", conversationID: conversationID, clientRequestID: "confirmed",
                        seq: 1, role: "user", text: "继续", createdAt: "now"),
            ChatMessage(id: "server-assistant", conversationID: conversationID, clientRequestID: "assistant-key",
                        seq: 2, role: "assistant", text: "回复", createdAt: "now"),
            ChatMessage(id: "server-system", conversationID: conversationID, clientRequestID: "system-key",
                        seq: 3, role: "system", text: "状态", createdAt: "now"),
            ChatMessage(id: "server-user-without-key", conversationID: conversationID, clientRequestID: nil,
                        seq: 4, role: "user", text: "继续", createdAt: "now")
        ])
        await model.refresh()

        let remaining = [otherKey, otherConversation, assistantOnly, systemOnly]
        XCTAssertEqual(model.pendingMessages, remaining)
        XCTAssertEqual(model.messages.count, 4)
        let saved = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(saved.pendingMessages, remaining, "确认结果必须落盘，重启不能恢复已确认待发项")
        XCTAssertEqual(saved.conversationStates.first { $0.conversationID == conversationID }?.cursor, 4)
        let sends = await api.recordedSends()
        XCTAssertTrue(sends.isEmpty, "同步确认不能额外发送消息")
    }

    @MainActor
    private func makeModel(api: PendingMessageAPI, pending: [PendingMessage] = []) async throws -> (AppModel, PendingSnapshotStore) {
        let conversation = try PendingValues.conversation()
        let snapshot = CachedSnapshot(savedAt: "2026-01-01T00:00:00Z", conversations: [conversation],
            selectedConversationID: conversation.id,
            conversationStates: [ConversationSnapshot(conversationID: conversation.id, messages: [], cursor: 0)],
            pendingMessages: pending)
        // 真正经过 Codable 往返，模拟重启后从磁盘读取的值。
        let restored = try JSONDecoder().decode(CachedSnapshot.self, from: JSONEncoder().encode(snapshot))
        let store = PendingSnapshotStore(snapshot: restored)
        let model = AppModel(serverURL: URL(string: "https://stub.invalid")!, api: api,
            credentials: PendingCredentialStore(session: try PendingValues.session()), store: store)
        await model.bootstrap()
        XCTAssertTrue(model.phase.isReady)
        XCTAssertEqual(model.selectedConversationID, conversation.id)
        return (model, store)
    }
}

private enum PendingValues {
    static let conversationID = "conversation-1"

    static func session() throws -> AuthSession {
        try JSONDecoder().decode(AuthSession.self, from: Data(#"{"token":"test-token","device":{"id":"test-device","name":"iPhone","role":"client","createdAt":"2026-01-01T00:00:00Z"}}"#.utf8))
    }

    static func conversation() throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"conversation-1","ownerId":"default","title":"聊天","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8))
    }

    static func page(messages: [ChatMessage], after: Int) throws -> MessagePage {
        struct WirePage: Encodable { let messages: [ChatMessage]; let nextCursor: Int }
        let page = WirePage(messages: messages, nextCursor: messages.last?.seq ?? after)
        return try JSONDecoder().decode(MessagePage.self, from: JSONEncoder().encode(page))
    }

    static func ack(conversationID: String, request: SendMessageRequest, seq: Int) throws -> SendMessageAck {
        let messageID = "message-\(request.clientRequestID)"
        let body: [String: Any] = [
            "message": ["id": messageID, "conversationId": conversationID, "clientRequestId": request.clientRequestID,
                        "seq": seq, "role": "user", "text": request.text, "createdAt": "2026-01-01T00:00:00Z"],
            "run": ["id": "run-\(request.clientRequestID)", "conversationId": conversationID,
                    "messageId": messageID, "status": "queued"],
            "created": true
        ]
        return try JSONDecoder().decode(SendMessageAck.self, from: JSONSerialization.data(withJSONObject: body))
    }
}

private struct RecordedPendingSend: Sendable {
    let conversationID: String
    let request: SendMessageRequest
}

private actor PendingMessageAPI: POSAPI {
    private let session: AuthSession
    private let conversation: Conversation
    private var sendFailures: [POSAPIError]
    private var sends: [RecordedPendingSend] = []
    private var messagesToRead: [ChatMessage] = []

    init(sendFailures: [POSAPIError] = []) throws {
        session = try PendingValues.session()
        conversation = try PendingValues.conversation()
        self.sendFailures = sendFailures
    }

    func recordedSends() -> [RecordedPendingSend] { sends }
    func setMessages(_ messages: [ChatMessage]) { messagesToRead = messages }
    func health() async throws -> HealthResponse {
        try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"ok":true,"service":"personal-os-cloud","protocolVersion":2}"#.utf8))
    }
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession { session }
    func me(_ session: AuthSession) async throws -> DeviceInfo { self.session.device }
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation { conversation }
    func conversations(_ session: AuthSession) async throws -> [Conversation] { [conversation] }
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage {
        if waitSeconds > 0 {
            // 后台长轮询保持挂起；signOut 会取消它。断言使用明确的 refresh，不依赖调度时机。
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        let incoming = messagesToRead.filter { $0.conversationID == conversationID && $0.seq > after }
        return try PendingValues.page(messages: incoming, after: after)
    }
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck {
        sends.append(RecordedPendingSend(conversationID: conversationID, request: request))
        if !sendFailures.isEmpty { throw sendFailures.removeFirst() }
        return try PendingValues.ack(conversationID: conversationID, request: request, seq: sends.count)
    }
}

private struct PendingCredentialStore: CredentialStore {
    let session: AuthSession
    func load() throws -> AuthSession? { session }
    func save(_ session: AuthSession) throws {}
    func clear() throws {}
}

private final class PendingSnapshotStore: SnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CachedSnapshot

    init(snapshot: CachedSnapshot) { self.snapshot = snapshot }
    func loadSnapshot() throws -> CachedSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
    func saveSnapshot(_ snapshot: CachedSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
    }
}
