import Foundation
import XCTest
import POSCore
import POSFeatures

final class AppModelRunTests: XCTestCase {
    @MainActor
    func testSendPersistsRunWithoutAdvancingMessageCursor() async throws {
        let api = try RunStateAPI()
        let (model, store) = try await makeModel(api)
        defer { model.signOut() }
        await model.send("hello")
        XCTAssertEqual(model.runRecords.first?.status, .queued)
        let snapshot = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(snapshot.runRecords, model.runRecords)
        XCTAssertEqual(snapshot.conversationStates.first { $0.conversationID == "a" }?.cursor, 0)
        XCTAssertTrue(snapshot.pendingMessages.isEmpty)
    }

    @MainActor
    func testRestoredRunReachesFailedAndTerminalRunsStopQuerying() async throws {
        let api = try RunStateAPI(status: "failed", error: "model timeout")
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .running)
        let updated = expectation(description: "restored run becomes failed")
        let store = try RunStateStore(records: [record])
        store.observe { snapshot in
            if snapshot.runRecords.first?.status == .failed { updated.fulfill() }
        }
        let (model, _) = try await makeModel(api, store: store)
        defer { model.signOut() }
        await fulfillment(of: [updated], timeout: 2)
        store.observe(nil)
        XCTAssertEqual(model.runRecords.first?.status, .failed)
        XCTAssertEqual(model.runRecords.first?.serverError, "model timeout")
        XCTAssertTrue(model.connection.isOnline, "生成失败不能伪装成连接断开")
        let count = await api.queryCount()
        await model.refreshRunStates()
        assertActorValue( await api.queryCount(), count)
    }

    @MainActor
    func testCancelSuccessPersistsTerminalAndRejectsLateRunningQuery() async throws {
        let api = try RunStateAPI(holdQuery: true)
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .queued)
        let (model, store) = try await makeModel(api, records: [record])
        defer { model.signOut() }
        await api.waitForQuery()
        await model.cancelRun("run-1")
        XCTAssertEqual(model.runRecords.first?.status, .canceled)
        XCTAssertEqual(try store.loadSnapshot()?.runRecords.first?.status, .canceled)
        await api.releaseQuery()
        await model.refreshRunStates()
        XCTAssertEqual(model.runRecords.first?.status, .canceled)
    }

    @MainActor
    func testCancelFailureKeepsActualStatusAndShowsUnconfirmedError() async throws {
        let api = try RunStateAPI(holdQuery: true, cancelFails: true)
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .queued)
        let (model, store) = try await makeModel(api, records: [record])
        defer { model.signOut() }
        await api.waitForQuery()
        await model.cancelRun("run-1")
        XCTAssertEqual(model.runRecords.first?.status, .queued)
        XCTAssertTrue(model.runRecords.first?.cancellationError?.contains("取消结果未确认") == true)
        XCTAssertEqual(try store.loadSnapshot()?.runRecords.first?.status, .queued)
        XCTAssertTrue(model.connection.isOnline)
        model.signOut()
        await api.releaseQuery()
    }

    @MainActor
    func testSwitchConversationDiscardsSuspendedRunResponse() async throws {
        let api = try RunStateAPI(status: "failed", holdQuery: true)
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .queued)
        let (model, _) = try await makeModel(api, records: [record])
        defer { model.signOut() }
        await api.waitForQuery()
        model.selectConversation("b")
        await api.releaseQuery()
        await model.refreshRunStates()
        XCTAssertEqual(model.selectedConversationID, "b")
        XCTAssertTrue(model.currentRunRecords.isEmpty)
        XCTAssertEqual(model.runRecords.first?.status, .queued)
    }

    @MainActor
    func testSignOutDiscardsSuspendedRunAndCancelResponse() async throws {
        let api = try RunStateAPI(holdQuery: true, holdCancel: true)
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .queued)
        let (model, _) = try await makeModel(api, records: [record])
        await api.waitForQuery()
        let cancel = Task { await model.cancelRun("run-1") }
        await api.waitForCancel()
        model.signOut()
        await api.releaseCancel()
        await api.releaseQuery()
        await cancel.value
        XCTAssertTrue(model.runRecords.isEmpty)
        XCTAssertTrue(model.cancelingRunIDs.isEmpty)
        XCTAssertNil(model.session)
    }

    @MainActor
    func testBackgroundStopsLocalPollingWithoutCancelingRemoteRun() async throws {
        let api = try RunStateAPI(holdQuery: true)
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .queued)
        let (model, _) = try await makeModel(api, records: [record])
        defer { model.signOut() }
        await api.waitForQuery()
        await model.setApplicationActive(false)
        await api.releaseQuery()
        let count = await api.queryCount()
        await model.refreshRunStates()
        assertActorValue( await api.queryCount(), count)
        assertActorValue( await api.cancelCount(), 0)
        XCTAssertEqual(model.runRecords.first?.status, .queued)
        await model.setApplicationActive(true)
        await model.refreshRunStates()
        XCTAssertEqual(model.runRecords.first?.status, .running)
    }

    @MainActor
    func testForegroundDuringRefreshResumesMessageAndRunPolling() async throws {
        let api = try RunStateAPI()
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .queued)
        let (model, _) = try await makeModel(api, records: [record])
        defer { model.signOut() }
        await api.waitForQuery()
        await api.waitForLongPoll()
        await api.holdNextHealth()
        let refresh = Task { await model.refresh() }
        await api.waitForHealth()
        await model.setApplicationActive(false)
        await model.setApplicationActive(true)
        XCTAssertTrue(model.isRefreshing, "回前台时原刷新仍在等待健康检查")

        let messagesResumed = expectation(description: "message polling resumed")
        let runsResumed = expectation(description: "run polling resumed")
        await api.observeNextActivity(run: { runsResumed.fulfill() }, messages: { messagesResumed.fulfill() })
        await api.releaseHealth()
        await refresh.value
        await fulfillment(of: [messagesResumed, runsResumed], timeout: 2)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.connection.isOnline)
        XCTAssertEqual(model.runRecords.first?.status, .running)
    }

    @MainActor
    func testFailedRePairClearsCanceledIdentityBusyState() async throws {
        let api = try RunStateAPI(cancelFails: true, holdCancel: true, pairFails: true)
        let record = RunRecord(runID: "run-1", conversationID: "a", messageID: "m1", status: .running)
        let (model, _) = try await makeModel(api, records: [record])
        defer { model.signOut() }
        let cancellation = Task { await model.cancelRun("run-1") }
        await api.waitForCancel()
        XCTAssertTrue(model.cancelingRunIDs.contains("run-1"))
        await model.pair(serverURL: model.serverURL, secret: "test-pair-secret", deviceName: "iPhone")
        XCTAssertTrue(model.phase.isReady)
        XCTAssertTrue(model.cancelingRunIDs.isEmpty)
        await api.releaseCancel()
        await cancellation.value
        await model.cancelRun("run-1")
        assertActorValue(await api.cancelCount(), 2)
        XCTAssertTrue(model.cancelingRunIDs.isEmpty)
        XCTAssertTrue(model.runRecords.first?.cancellationError?.contains("取消结果未确认") == true)
    }

    @MainActor
    private func makeModel(_ api: RunStateAPI, records: [RunRecord] = [], store: RunStateStore? = nil) async throws -> (AppModel, RunStateStore) {
        let cache = try store ?? RunStateStore(records: records)
        let credentials = try RunStateCredentials()
        let model = AppModel(serverURL: URL(string: "https://stub.invalid")!, api: api, credentials: credentials, store: cache)
        await model.bootstrap()
        XCTAssertTrue(model.phase.isReady)
        return (model, cache)
    }

    // Keep actor reads outside XCTest's synchronous autoclosures.
    private func assertActorValue<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, file: file, line: line)
    }
}

private func decodeRun<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}

private actor RunStateAPI: POSAPI {
    private let status: String
    private let error: String?
    private var holdQuery: Bool
    private var holdCancel: Bool
    private let cancelFails: Bool
    private let pairFails: Bool
    private var queries = 0
    private var cancellations = 0
    private var queryGate: CheckedContinuation<Void, Never>?
    private var cancelGate: CheckedContinuation<Void, Never>?
    private var queryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var longPollWaiters: [CheckedContinuation<Void, Never>] = []
    private var longPolls = 0
    private var holdHealth = false
    private var healthGate: CheckedContinuation<Void, Never>?
    private var healthWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextRunQuery: (@Sendable () -> Void)?
    private var nextLongPoll: (@Sendable () -> Void)?

    init(status: String = "running", error: String? = nil, holdQuery: Bool = false, cancelFails: Bool = false, holdCancel: Bool = false, pairFails: Bool = false) throws {
        self.status = status; self.error = error; self.holdQuery = holdQuery
        self.cancelFails = cancelFails; self.holdCancel = holdCancel; self.pairFails = pairFails
    }
    func queryCount() -> Int { queries }
    func cancelCount() -> Int { cancellations }
    func waitForQuery() async {
        if queries > 0 { return }
        await withCheckedContinuation { queryWaiters.append($0) }
    }
    func waitForCancel() async {
        if cancellations > 0 { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
    func releaseQuery() { holdQuery = false; queryGate?.resume(); queryGate = nil }
    func releaseCancel() { holdCancel = false; cancelGate?.resume(); cancelGate = nil }
    func waitForLongPoll() async {
        if longPolls > 0 { return }
        await withCheckedContinuation { longPollWaiters.append($0) }
    }
    func holdNextHealth() { holdHealth = true }
    func waitForHealth() async {
        if healthGate != nil { return }
        await withCheckedContinuation { healthWaiters.append($0) }
    }
    func releaseHealth() { holdHealth = false; healthGate?.resume(); healthGate = nil }
    func observeNextActivity(run: @escaping @Sendable () -> Void, messages: @escaping @Sendable () -> Void) {
        nextRunQuery = run
        nextLongPoll = messages
    }
    func health() async throws -> HealthResponse {
        if holdHealth {
            await withCheckedContinuation { continuation in
                healthGate = continuation
                for waiter in healthWaiters { waiter.resume() }; healthWaiters = []
            }
        }
        return try decodeRun(["ok": true, "service": "personal-os-cloud", "protocolVersion": 2])
    }
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession {
        if pairFails { throw POSAPIError.transport("pairing offline") }
        return try RunStateCredentials.session()
    }
    func me(_ session: AuthSession) async throws -> DeviceInfo { session.device }
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation { try Self.conversation("a") }
    func conversations(_ session: AuthSession) async throws -> [Conversation] { try [Self.conversation("a"), Self.conversation("b")] }
    static func conversation(_ id: String) throws -> Conversation {
        try decodeRun(["id": id, "ownerId": "default", "title": id, "createdAt": "now", "updatedAt": "now"])
    }
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage {
        if waitSeconds > 0 {
            longPolls += 1
            for waiter in longPollWaiters { waiter.resume() }; longPollWaiters = []
            let action = nextLongPoll; nextLongPoll = nil; action?()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return try decodeRun(["messages": [], "nextCursor": after])
    }
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck {
        try decodeRun([
            "message": ["id": "m1", "conversationId": conversationID, "clientRequestId": request.clientRequestID,
                        "seq": 1, "role": "user", "text": request.text, "createdAt": "now"],
            "run": ["id": "run-1", "conversationId": conversationID, "messageId": "m1", "status": "queued"], "created": true
        ])
    }
    func run(_ session: AuthSession, runID: String) async throws -> Run {
        queries += 1
        let action = nextRunQuery; nextRunQuery = nil; action?()
        for waiter in queryWaiters { waiter.resume() }; queryWaiters = []
        if holdQuery { await withCheckedContinuation { queryGate = $0 } }
        var body: [String: Any] = ["id": runID, "conversationId": "a", "messageId": "m1", "status": status]
        if let error { body["error"] = error }
        return try decodeRun(body)
    }
    func cancelRun(_ session: AuthSession, runID: String) async throws -> Run {
        cancellations += 1
        for waiter in cancelWaiters { waiter.resume() }; cancelWaiters = []
        if holdCancel { await withCheckedContinuation { cancelGate = $0 } }
        if cancelFails { throw POSAPIError.transport("offline") }
        return try decodeRun(["id": runID, "conversationId": "a", "messageId": "m1", "status": "canceled"])
    }
}

private final class RunStateCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession?
    init() throws { value = try Self.session() }
    static func session() throws -> AuthSession {
        try decodeRun(["token": "test-token", "device": ["id": "test-device", "name": "iPhone", "role": "client", "createdAt": "now"]])
    }
    func load() throws -> AuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: AuthSession) throws { lock.lock(); defer { lock.unlock() }; value = session }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

private final class RunStateStore: SnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CachedSnapshot
    private var observer: (@Sendable (CachedSnapshot) -> Void)?
    init(records: [RunRecord]) throws {
        snapshot = CachedSnapshot(savedAt: "now", conversations: try [RunStateAPI.conversation("a"), RunStateAPI.conversation("b")],
            selectedConversationID: "a", conversationStates: [ConversationSnapshot(conversationID: "a", messages: [], cursor: 0)], runRecords: records)
    }
    func observe(_ action: (@Sendable (CachedSnapshot) -> Void)?) { lock.lock(); defer { lock.unlock() }; observer = action }
    func loadSnapshot() throws -> CachedSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
    func saveSnapshot(_ snapshot: CachedSnapshot) throws {
        lock.lock(); self.snapshot = snapshot; let action = observer; lock.unlock()
        action?(snapshot)
    }
}
