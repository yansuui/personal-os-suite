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
        let knownRun = RunRecord(runID: "known-run", conversationID: conversationID, messageID: "server-user", status: .running)
        let (model, store) = try await makeModel(api: api, pending: pending, runRecords: [knownRun])
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
    func testLostAckKeepsRequestAcrossPollingAndRestartUntilRunIsRecovered() async throws {
        let api = try PendingMessageAPI(sendFailures: [.transport("ack lost"), .transport("ack lost")], commitBeforeSendFailure: true)
        let (model, store) = try await makeModel(api: api)
        await model.send("保留运行回执恢复")
        let pending = try XCTUnwrap(model.pendingMessages.first)
        await model.refresh()
        XCTAssertEqual(model.messages.count, 1, "服务端已接受正文")
        XCTAssertEqual(model.pendingMessages, [pending], "仅确认正文时必须保留原请求键")
        XCTAssertTrue(model.runRecords.isEmpty)
        XCTAssertEqual(try store.loadSnapshot()?.pendingMessages, [pending])
        model.signOut()

        let restored = AppModel(serverURL: URL(string: "https://stub.invalid")!, api: api,
            credentials: PendingCredentialStore(session: try PendingValues.session()), store: store)
        defer { restored.signOut() }
        await restored.bootstrap()
        XCTAssertEqual(restored.pendingMessages, [pending])
        await restored.retryPending(pending)
        let sends = await api.recordedSends()
        XCTAssertEqual(sends.count, 3)
        XCTAssertTrue(sends.allSatisfy { $0.request == pending.request })
        let acceptedCount = await api.acceptedMessageCount()
        XCTAssertEqual(acceptedCount, 1, "恢复运行不能创建第二条服务端消息")
        XCTAssertTrue(restored.pendingMessages.isEmpty)
        XCTAssertEqual(restored.messages.count, 1)
        let run = try XCTUnwrap(restored.runRecords.first)
        XCTAssertEqual(run.runID, "run-\(pending.clientRequestID)")
        XCTAssertEqual(run.messageID, restored.messages.first?.id)
        await restored.cancelRun(run.runID)
        XCTAssertEqual(restored.runRecords.first?.status, .canceled)
        XCTAssertEqual(try store.loadSnapshot()?.runRecords.first?.status, .canceled)
    }

    @MainActor
    func testRestoredSessionRejectsIncompatibleHealthBeforeAuthenticatedRequests() async throws {
        for status in [401, 403, 404] {
            let api = try PendingMessageAPI(healthFailure: .server(status: status, code: "v2_unavailable", message: PendingValues.incompatibleDetail))
            let credentials = PendingCredentialStore(session: try PendingValues.session())
            let (model, store) = try await makeModel(api: api, pending: [PendingValues.pending], cachedMessages: [PendingValues.cachedMessage], credentials: credentials, expectsReady: false)
            defer { model.signOut() }
            XCTAssertEqual(model.phase.failureMessage, PendingValues.incompatibleDetail)
            XCTAssertEqual(model.notice, PendingValues.incompatibleDetail)
            XCTAssertEqual(model.connection.offlineReason, PendingValues.incompatibleDetail)
            let calls = await api.recordedCalls()
            XCTAssertEqual(calls, ["health"], "health失败不得请求me、会话、消息或pair")
            try assertRestoredStatePreserved(model, store: store, credentials: credentials)
        }
    }

    @MainActor
    func testRestoredSessionKeepsReadyAndOfflineCacheOnHealthTransportFailure() async throws {
        let api = try PendingMessageAPI(healthFailure: .transport("connection refused"))
        let credentials = PendingCredentialStore(session: try PendingValues.session())
        let (model, store) = try await makeModel(api: api, pending: [PendingValues.pending], cachedMessages: [PendingValues.cachedMessage], credentials: credentials)
        defer { model.signOut() }
        XCTAssertNil(model.phase.failureMessage)
        XCTAssertEqual(model.connection.offlineReason, "网络不可达：connection refused")
        XCTAssertEqual(model.notice, "网络不可达：connection refused")
        let calls = await api.recordedCalls()
        XCTAssertEqual(calls, ["health"], "网络恢复后需先重连验证协议，不能跳过health轮询")
        try assertRestoredStatePreserved(model, store: store, credentials: credentials)
    }

    @MainActor
    func testRestoredSessionRequiresPairingWhenCompatibleServerRejectsOldToken() async throws {
        let api = try PendingMessageAPI(meFailure: .unauthorized)
        let credentials = PendingCredentialStore(session: try PendingValues.session())
        let (model, store) = try await makeModel(api: api, pending: [PendingValues.pending], cachedMessages: [PendingValues.cachedMessage], credentials: credentials, expectsReady: false)
        defer { model.signOut() }
        XCTAssertEqual(model.phase.failureMessage, "登录已失效，请重新配对")
        XCTAssertEqual(model.connection.offlineReason, "登录已失效，请重新配对")
        let calls = await api.recordedCalls()
        XCTAssertEqual(calls, ["health", "me"], "协议通过后才验证token，失效后不可同步消息")
        try assertRestoredStatePreserved(model, store: store, credentials: credentials)
    }

    @MainActor
    func testPairHealthFailureCannotRestoreAnIncompatibleSessionOrBlameSecret() async throws {
        let api = try PendingMessageAPI(healthFailure: .server(status: 404, code: "v2_unavailable", message: PendingValues.incompatibleDetail))
        let credentials = PendingCredentialStore(session: try PendingValues.session())
        let (model, store) = try await makeModel(api: api, pending: [PendingValues.pending], cachedMessages: [PendingValues.cachedMessage], credentials: credentials, expectsReady: false)
        defer { model.signOut() }
        let failures: [POSAPIError] = [
            .server(status: 401, code: "v2_unavailable", message: PendingValues.incompatibleDetail),
            .server(status: 403, code: "v2_unavailable", message: PendingValues.incompatibleDetail),
            .server(status: 404, code: "v2_unavailable", message: PendingValues.incompatibleDetail),
            .transport("connection refused")
        ]
        for (index, failure) in failures.enumerated() {
            await api.setHealthFailure(failure)
            await model.pair(serverURL: URL(string: "https://stub.invalid")!, secret: String(repeating: "x", count: 8), deviceName: "iPhone")
            let expected: String
            if case .transport = failure { expected = "连不上服务器：connection refused。请确认地址、端口和局域网可达" }
            else { expected = PendingValues.incompatibleDetail }
            XCTAssertFalse(model.phase.isReady, "failed旧会话虽保留凭据，也不能恢复ready")
            XCTAssertEqual(model.phase.failureMessage, expected)
            XCTAssertFalse(model.phase.failureMessage?.contains("配对密钥错误") ?? true)
            let calls = await api.recordedCalls()
            XCTAssertEqual(calls, Array(repeating: "health", count: index + 2), "health未通过不可发pair/me/messages")
            try assertRestoredStatePreserved(model, store: store, credentials: credentials)
        }
    }

    @MainActor
    func testStartupActionsCannotBypassSuspendedHealthAndPendingSendIsPreserved() async throws {
        let api = try PendingMessageAPI()
        await api.holdHealth()
        let unexpected = expectation(description: "health通过前不能发业务请求")
        unexpected.isInverted = true
        await api.observeBusinessRequests { unexpected.fulfill() }
        let first = try PendingValues.conversation()
        let second = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"conversation-2","ownerId":"default","title":"另一会话","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8))
        let snapshot = CachedSnapshot(savedAt: "2026-01-01T00:00:00Z", conversations: [first, second],
            selectedConversationID: first.id,
            conversationStates: [ConversationSnapshot(conversationID: first.id, messages: [], cursor: 0),
                                 ConversationSnapshot(conversationID: second.id, messages: [], cursor: 0)])
        let store = PendingSnapshotStore(snapshot: snapshot)
        let model = AppModel(serverURL: URL(string: "https://stub.invalid")!, api: api,
            credentials: PendingCredentialStore(session: try PendingValues.session()), store: store)
        defer { model.signOut() }
        let boot = Task { await model.bootstrap() }
        await api.waitForHealthRequested()
        XCTAssertTrue(model.isRefreshing)
        await model.reconnect()
        model.selectConversation(second.id)
        await model.createConversation()
        await model.send("检查期间的消息")
        await fulfillment(of: [unexpected], timeout: 0.2)
        let callsBeforeHealth = await api.recordedCalls()
        XCTAssertEqual(callsBeforeHealth, ["health"])
        let suspended = await api.healthIsSuspended()
        XCTAssertTrue(suspended, "负断言期间health必须仍然挂起")
        XCTAssertEqual(model.pendingMessages.count, 1)
        XCTAssertEqual(model.pendingMessages.first?.text, "检查期间的消息")
        XCTAssertEqual(model.pendingMessages.first?.conversationID, second.id)
        XCTAssertEqual(try store.loadSnapshot()?.pendingMessages, model.pendingMessages)
        XCTAssertEqual(model.notice, "服务器连接尚未验证，消息已保留待发")
        await api.observeBusinessRequests(nil)
        await api.releaseHealth()
        await boot.value
        XCTAssertTrue(model.phase.isReady)
        XCTAssertTrue(model.connection.isOnline)
        XCTAssertEqual(model.selectedConversationID, second.id)
        XCTAssertEqual(model.pendingMessages.count, 1, "检查通过也不能隐式重发用户的待发消息")
        let sends = await api.recordedSends()
        XCTAssertTrue(sends.isEmpty)
    }

    @MainActor
    func testRefreshTrimsUpdatesAndClearsServerModel() async throws {
        let api = try PendingMessageAPI(healthModel: " \n model-first \t")
        let (model, _) = try await makeModel(api: api)
        defer { model.signOut() }
        await model.setApplicationActive(false)
        XCTAssertEqual(model.serverModel, "model-first")
        XCTAssertEqual(model.modelDisplayName, "model-first")

        for value in ["model-next", " \n\t", "model-restored", nil] as [String?] {
            await api.setHealthModel(value)
            await model.refresh()
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = trimmed?.isEmpty == false ? trimmed : nil
            XCTAssertEqual(model.serverModel, expected)
            XCTAssertEqual(model.modelDisplayName, expected ?? "服务器未提供型号")
        }
    }

    @MainActor
    func testHealthFailureCannotPresentOldModelAsCurrentWhenChatReconnects() async throws {
        let api = try PendingMessageAPI(healthModel: "model-first")
        let (model, _) = try await makeModel(api: api)
        defer { model.signOut() }
        await model.setApplicationActive(false)
        await api.setHealthFailure(.transport("offline"))
        await model.refresh()
        XCTAssertFalse(model.connection.isOnline)
        XCTAssertEqual(model.serverModel, "model-first")
        XCTAssertEqual(model.modelDisplayName, "model-first（上次连接）")

        // 其他聊天请求成功不能代替健康检查，旧型号仍然只能作为上次连接信息。
        await model.createConversation()
        XCTAssertTrue(model.connection.isOnline)
        XCTAssertEqual(model.modelDisplayName, "model-first（上次连接）")
        await api.setHealthFailure(nil)
        await api.setHealthModel("model-next")
        await model.refresh()
        XCTAssertEqual(model.modelDisplayName, "model-next")
    }

    @MainActor
    func testHealthFailureWithoutKnownModelShowsNotProvided() async throws {
        let api = try PendingMessageAPI(healthFailure: .transport("offline"), healthModel: "unverified-model")
        let (model, _) = try await makeModel(api: api)
        defer { model.signOut() }
        XCTAssertFalse(model.connection.isOnline)
        XCTAssertNil(model.serverModel)
        XCTAssertEqual(model.modelDisplayName, "服务器未提供型号")
    }

    @MainActor
    func testHealthModelWaitsForMeAndIsNotAppliedWhenMeFails() async throws {
        let api = try PendingMessageAPI(healthModel: "model-first")
        let (model, _) = try await makeModel(api: api)
        defer { model.signOut() }
        await model.setApplicationActive(false)
        await api.setHealthModel("unverified-model")
        await api.setMeFailure(.unauthorized)
        await api.holdNextMe()
        let refresh = Task { await model.refresh() }
        await api.waitForSuspendedMe()
        XCTAssertEqual(model.serverModel, "model-first", "me 通过前不能应用公开 health 的新型号")
        XCTAssertEqual(model.modelDisplayName, "model-first（上次连接）")
        await api.releaseMe()
        await refresh.value
        XCTAssertEqual(model.phase.failureMessage, "登录已失效，请重新配对")
        XCTAssertEqual(model.serverModel, "model-first")
        XCTAssertEqual(model.modelDisplayName, "model-first（上次连接）")
    }

    @MainActor
    func testSignOutClearsModelAndDiscardsSuspendedHealth() async throws {
        let api = try PendingMessageAPI(healthModel: "model-first")
        let (model, _) = try await makeModel(api: api)
        await model.setApplicationActive(false)
        await api.setHealthModel("late-model")
        await api.holdHealth()
        let refresh = Task { await model.refresh() }
        await api.waitForSuspendedHealth()
        model.signOut()
        XCTAssertNil(model.serverModel)
        await api.releaseHealth()
        await refresh.value
        XCTAssertNil(model.serverModel)
        XCTAssertEqual(model.modelDisplayName, "服务器未提供型号")
        XCTAssertNil(model.session)
        XCTAssertFalse(model.isRefreshing)
    }

    @MainActor
    func testNewIdentityClearsModelAndDiscardsOldMeResponse() async throws {
        let api = try PendingMessageAPI(healthModel: "old-model")
        let (model, _) = try await makeModel(api: api)
        defer { model.signOut() }
        await model.setApplicationActive(false)
        await api.setHealthModel("late-old-model")
        await api.holdNextMe()
        let oldRefresh = Task { await model.refresh() }
        await api.waitForSuspendedMe()

        let newSession = try JSONDecoder().decode(AuthSession.self, from: Data(#"{"token":"new-token","device":{"id":"new-device","name":"另一台 iPhone","role":"client","createdAt":"now"}}"#.utf8))
        await api.setSession(newSession)
        await api.setHealthModel("new-model")
        await api.holdHealth()
        let pair = Task { await model.pair(serverURL: URL(string: "https://new-stub.invalid")!, secret: "test-pair-secret", deviceName: "另一台 iPhone") }
        await api.waitForSuspendedHealth()
        XCTAssertNil(model.serverModel, "新身份开始配对时立即清除旧型号")
        await api.releaseHealth()
        await pair.value
        XCTAssertEqual(model.session, newSession)
        XCTAssertEqual(model.modelDisplayName, "new-model")
        await api.releaseMe()
        await oldRefresh.value
        XCTAssertEqual(model.serverModel, "new-model", "旧身份的 me 迟到不能覆盖新身份型号")
        XCTAssertEqual(model.modelDisplayName, "new-model")
    }

    @MainActor
    private func assertRestoredStatePreserved(_ model: AppModel, store: PendingSnapshotStore, credentials: PendingCredentialStore,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = store.initialSnapshot
        XCTAssertEqual(model.pendingMessages, snapshot.pendingMessages, file: file, line: line)
        XCTAssertEqual(model.messages, snapshot.conversationStates.first?.messages ?? [], file: file, line: line)
        XCTAssertEqual(model.conversations, snapshot.conversations, file: file, line: line)
        XCTAssertEqual(model.selectedConversationID, snapshot.selectedConversationID, file: file, line: line)
        XCTAssertEqual(try store.loadSnapshot(), snapshot, "失败不得改写本地快照", file: file, line: line)
        let session = try PendingValues.session()
        XCTAssertEqual(model.session, session, file: file, line: line)
        XCTAssertEqual(try credentials.load(), session, file: file, line: line)
        XCTAssertEqual(credentials.recordedMutationCount(), 0, "失败不得删除或替换凭据", file: file, line: line)
    }

    @MainActor
    private func makeModel(api: PendingMessageAPI, pending: [PendingMessage] = [], cachedMessages: [ChatMessage] = [],
                           credentials: PendingCredentialStore? = nil, expectsReady: Bool = true,
                           runRecords: [RunRecord] = []) async throws -> (AppModel, PendingSnapshotStore) {
        let conversation = try PendingValues.conversation()
        let snapshot = CachedSnapshot(savedAt: "2026-01-01T00:00:00Z", conversations: [conversation], selectedConversationID: conversation.id,
            conversationStates: [ConversationSnapshot(conversationID: conversation.id, messages: cachedMessages, cursor: cachedMessages.last?.seq ?? 0)],
            pendingMessages: pending, runRecords: runRecords)
        let restored = try JSONDecoder().decode(CachedSnapshot.self, from: JSONEncoder().encode(snapshot))
        let store = PendingSnapshotStore(snapshot: restored)
        let credentialStore: PendingCredentialStore
        if let credentials { credentialStore = credentials }
        else { credentialStore = PendingCredentialStore(session: try PendingValues.session()) }
        let model = AppModel(serverURL: URL(string: "https://stub.invalid")!, api: api, credentials: credentialStore, store: store)
        await model.bootstrap()
        XCTAssertEqual(model.phase.isReady, expectsReady)
        XCTAssertEqual(model.selectedConversationID, conversation.id)
        return (model, store)
    }
}

private enum PendingValues {
    static let conversationID = "conversation-1"
    static let incompatibleDetail = "当前地址未提供可用的 v2 服务。请更新云端服务并检查 /v2/* 转发，或填写 v2 服务器地址后重新配对。"
    static var pending: PendingMessage {
        PendingMessage(conversationID: conversationID, clientRequestID: "cached-pending", text: "保留待发", createdAt: "2026-01-01T00:00:00Z")
    }
    static var cachedMessage: ChatMessage {
        ChatMessage(id: "cached-message", conversationID: conversationID, clientRequestID: nil, seq: 7, role: "assistant", text: "离线缓存", createdAt: "2026-01-01T00:00:00Z")
    }
    static func session() throws -> AuthSession {
        try JSONDecoder().decode(AuthSession.self, from: Data(#"{"token":"test-token","device":{"id":"test-device","name":"iPhone","role":"client","createdAt":"2026-01-01T00:00:00Z"}}"#.utf8))
    }
    static func conversation() throws -> Conversation {
        try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"conversation-1","ownerId":"default","title":"聊天","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8))
    }
    static func page(messages: [ChatMessage], after: Int) throws -> MessagePage {
        struct WirePage: Encodable { let messages: [ChatMessage]; let nextCursor: Int }
        return try JSONDecoder().decode(MessagePage.self, from: JSONEncoder().encode(WirePage(messages: messages, nextCursor: messages.last?.seq ?? after)))
    }
    static func ack(conversationID: String, request: SendMessageRequest, seq: Int) throws -> SendMessageAck {
        let messageID = "message-\(request.clientRequestID)"
        let body: [String: Any] = [
            "message": ["id": messageID, "conversationId": conversationID, "clientRequestId": request.clientRequestID,
                        "seq": seq, "role": "user", "text": request.text, "createdAt": "2026-01-01T00:00:00Z"],
            "run": ["id": "run-\(request.clientRequestID)", "conversationId": conversationID, "messageId": messageID, "status": "queued"], "created": true
        ]
        return try JSONDecoder().decode(SendMessageAck.self, from: JSONSerialization.data(withJSONObject: body))
    }
}

private struct RecordedPendingSend: Sendable {
    let conversationID: String
    let request: SendMessageRequest
}

private actor PendingMessageAPI: POSAPI {
    private var session: AuthSession
    private let conversation: Conversation
    private var sendFailures: [POSAPIError]
    private var healthFailure: POSAPIError?
    private var healthModel: String?
    private var meFailure: POSAPIError?
    private var sends: [RecordedPendingSend] = []
    private var calls: [String] = []
    private var messagesToRead: [ChatMessage] = []
    private var knownRuns: [String: Run] = [:]
    private var acceptedMessages: [String: SendMessageAck] = [:]
    private let commitBeforeSendFailure: Bool
    private var shouldHoldHealth = false
    private var healthGate: CheckedContinuation<Void, Never>?
    private var healthWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldMe = false
    private var meGate: CheckedContinuation<Void, Never>?
    private var meWaiters: [CheckedContinuation<Void, Never>] = []
    private var businessObserver: (@Sendable () -> Void)?

    init(sendFailures: [POSAPIError] = [], healthFailure: POSAPIError? = nil, meFailure: POSAPIError? = nil,
         commitBeforeSendFailure: Bool = false, healthModel: String? = nil) throws {
        session = try PendingValues.session()
        conversation = try PendingValues.conversation()
        self.sendFailures = sendFailures
        self.healthFailure = healthFailure
        self.healthModel = healthModel
        self.meFailure = meFailure
        self.commitBeforeSendFailure = commitBeforeSendFailure
    }
    func acceptedMessageCount() -> Int { acceptedMessages.count }
    func recordedSends() -> [RecordedPendingSend] { sends }
    func recordedCalls() -> [String] { calls }
    func setMessages(_ messages: [ChatMessage]) { messagesToRead = messages }
    func setHealthFailure(_ failure: POSAPIError?) { healthFailure = failure }
    func setHealthModel(_ model: String?) { healthModel = model }
    func setMeFailure(_ failure: POSAPIError?) { meFailure = failure }
    func setSession(_ session: AuthSession) { self.session = session }
    func holdNextMe() { shouldHoldMe = true }
    func waitForSuspendedMe() async {
        if meGate != nil { return }
        await withCheckedContinuation { meWaiters.append($0) }
    }
    func releaseMe() {
        meGate?.resume()
        meGate = nil
    }
    func holdHealth() { shouldHoldHealth = true }
    func waitForSuspendedHealth() async {
        if healthGate != nil { return }
        await withCheckedContinuation { healthWaiters.append($0) }
    }
    func healthIsSuspended() -> Bool { healthGate != nil }
    func observeBusinessRequests(_ observer: (@Sendable () -> Void)?) { businessObserver = observer }
    func waitForHealthRequested() async {
        if calls.contains("health") { return }
        await withCheckedContinuation { healthWaiters.append($0) }
    }
    func releaseHealth() {
        shouldHoldHealth = false
        healthGate?.resume()
        healthGate = nil
    }
    private func record(_ call: String) {
        calls.append(call)
        if call != "health" { businessObserver?() }
    }
    func health() async throws -> HealthResponse {
        record("health")
        if shouldHoldHealth {
            await withCheckedContinuation { continuation in
                healthGate = continuation
                for waiter in healthWaiters { waiter.resume() }
                healthWaiters.removeAll()
            }
        } else {
            for waiter in healthWaiters { waiter.resume() }
            healthWaiters.removeAll()
        }
        if let healthFailure { throw healthFailure }
        var body: [String: Any] = ["ok": true, "service": "personal-os-cloud", "protocolVersion": 2]
        if let healthModel { body["model"] = healthModel }
        return try JSONDecoder().decode(HealthResponse.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession {
        record("pair")
        return session
    }
    func me(_ session: AuthSession) async throws -> DeviceInfo {
        record("me")
        let device = self.session.device
        let failure = meFailure
        if shouldHoldMe {
            shouldHoldMe = false
            await withCheckedContinuation { continuation in
                meGate = continuation
                for waiter in meWaiters { waiter.resume() }
                meWaiters.removeAll()
            }
        }
        if let failure { throw failure }
        return device
    }
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation {
        record("createConversation")
        return conversation
    }
    func conversations(_ session: AuthSession) async throws -> [Conversation] {
        record("conversations")
        return [conversation]
    }
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage {
        record(waitSeconds > 0 ? "poll" : "messages")
        if waitSeconds > 0 {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        let incoming = messagesToRead.filter { $0.conversationID == conversationID && $0.seq > after }
        return try PendingValues.page(messages: incoming, after: after)
    }
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck {
        record("sendMessage")
        sends.append(RecordedPendingSend(conversationID: conversationID, request: request))
        let key = conversationID + "/" + request.clientRequestID
        let ack = try acceptedMessages[key] ?? PendingValues.ack(conversationID: conversationID, request: request, seq: acceptedMessages.count + 1)
        if commitBeforeSendFailure {
            acceptedMessages[key] = ack
            knownRuns[ack.run.id] = ack.run
            if !messagesToRead.contains(where: { $0.id == ack.message.id }) { messagesToRead.append(ack.message) }
        }
        if !sendFailures.isEmpty { throw sendFailures.removeFirst() }
        acceptedMessages[key] = ack
        knownRuns[ack.run.id] = ack.run
        return ack
    }
    func run(_ session: AuthSession, runID: String) async throws -> Run {
        guard let run = knownRuns[runID] else { throw POSAPIError.server(status: 404, code: "not_found", message: "Run not found") }
        return run
    }
    func cancelRun(_ session: AuthSession, runID: String) async throws -> Run {
        let previous = try await run(session, runID: runID)
        let data = try JSONSerialization.data(withJSONObject: ["id": previous.id, "conversationId": previous.conversationId,
            "messageId": previous.messageId, "status": "canceled"])
        let canceled = try JSONDecoder().decode(Run.self, from: data)
        knownRuns[runID] = canceled
        return canceled
    }
}

private final class PendingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?
    private var mutationCount = 0
    init(session: AuthSession) { self.session = session }
    func load() throws -> AuthSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
    func save(_ session: AuthSession) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
        mutationCount += 1
    }
    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        session = nil
        mutationCount += 1
    }
    func recordedMutationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return mutationCount
    }
}

private final class PendingSnapshotStore: SnapshotStore, @unchecked Sendable {
    let initialSnapshot: CachedSnapshot
    private let lock = NSLock()
    private var snapshot: CachedSnapshot
    init(snapshot: CachedSnapshot) {
        self.snapshot = snapshot
        self.initialSnapshot = snapshot
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
    }
}
