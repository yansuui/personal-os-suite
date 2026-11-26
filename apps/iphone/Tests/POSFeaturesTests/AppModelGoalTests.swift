import Foundation
import XCTest
import POSCore
import POSFeatures

final class AppModelGoalTests: XCTestCase {
    @MainActor
    func testLostGoalAckRestoresOriginalCommandWithoutDuplicateCreation() async throws {
        let api = try GoalScenarioAPI()
        await api.loseNextCreateAck()
        let (model, store) = try await makeModel(api)
        let id = model.beginGoalDraft(GoalDraft(id: "new-goal", kind: .createGoal, title: "重启后也只有一份", date: "2026-12-01"))
        let first = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertFalse(first)
        let savedDraft = try XCTUnwrap(try store.loadSnapshot()?.goalCache.drafts.first)
        XCTAssertEqual(savedDraft.state, .unconfirmed)
        let original = try XCTUnwrap(savedDraft.mutation)
        model.signOut()

        let (restored, _) = try await makeModel(api, store: store)
        defer { restored.signOut() }
        XCTAssertEqual(restored.goalDrafts[id]?.mutation, original)
        let succeeded = await restored.submitGoalDraft(id, identity: restored.cacheIdentityKey)
        XCTAssertTrue(succeeded)
        let requests = await api.recordedCreates()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first, requests.last)
        let count = await api.createdGoalCount()
        XCTAssertEqual(count, 1)
        XCTAssertNil(restored.goalDrafts[id])
    }

    @MainActor
    func testConflictKeepsInputAndOriginalRevisionUntilExplicitRebase() async throws {
        let api = try GoalScenarioAPI()
        let (model, _) = try await makeModel(api)
        defer { model.signOut() }
        await api.conflictNextGoalUpdate()
        let id = model.beginGoalDraft(GoalDraft(id: "edit", kind: .editGoal, goalID: "goal-1", expectedRevision: 1,
            title: "本地未丢失的标题", description: "本地说明", successCriteria: "", date: ""))
        let saved = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertFalse(saved)
        let conflicted = try XCTUnwrap(model.goalDrafts[id])
        XCTAssertEqual(conflicted.state, .conflict)
        XCTAssertEqual(conflicted.title, "本地未丢失的标题")
        XCTAssertEqual(conflicted.expectedRevision, 1)
        XCTAssertEqual(model.goalDetails["goal-1"]?.goal.title, "另一设备更新")
        var edited = conflicted
        edited.title = "不能修改已固定命令"
        model.updateGoalDraft(edited, identity: model.cacheIdentityKey)
        XCTAssertEqual(model.goalDrafts[id], conflicted)

        await model.reviseGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertEqual(model.goalDrafts[id]?.expectedRevision, 2)
        XCTAssertEqual(model.goalDrafts[id]?.title, conflicted.title)
        XCTAssertNil(model.goalDrafts[id]?.mutation)
        let resaved = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertTrue(resaved)
        let commands = await api.recordedGoalCommands()
        XCTAssertEqual(commands.map(\.expectedRevision), [1, 2])
        XCTAssertNotEqual(commands.first?.commandId, commands.last?.commandId)
    }

    @MainActor
    func testSnapshotFailurePreventsAnyNetworkMutation() async throws {
        let api = try GoalScenarioAPI()
        let (model, store) = try await makeModel(api)
        defer { model.signOut() }
        let id = model.beginGoalDraft(GoalDraft(id: "new-goal", kind: .createGoal, title: "必须先落盘"))
        store.setFailWrites(true)
        let saved = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertFalse(saved)
        let requests = await api.recordedCreates()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNotNil(model.goalDrafts[id]?.mutation)
    }

    @MainActor
    func testOfflineInputPersistsWithoutWritingOrChangingCloudReadTime() async throws {
        let api = try GoalScenarioAPI()
        await api.setHealthOffline(true)
        let store = try GoalScenarioStore(snapshot: GoalScenarioValues.snapshot())
        let (model, _) = try await makeModel(api, store: store, refreshGoals: false)
        defer { model.signOut() }
        let id = model.beginGoalDraft(GoalDraft(id: "offline", kind: .createGoal, title: "离线输入"))
        var draft = try XCTUnwrap(model.goalDrafts[id])
        draft.description = "关闭页面也保留"
        model.updateGoalDraft(draft, identity: model.cacheIdentityKey)
        let result = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertFalse(result)
        XCTAssertFalse(model.canEditGoals)
        XCTAssertEqual(try store.loadSnapshot()?.goalCache.drafts.first?.description, draft.description)
        XCTAssertEqual(model.goalsLastSyncedAt, "2026-11-25T00:00:00Z")
        let requests = await api.recordedCreates()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testSignOutDiscardsSuspendedMutationResponse() async throws {
        let api = try GoalScenarioAPI()
        let (model, store) = try await makeModel(api)
        await api.holdNextCreate()
        let id = model.beginGoalDraft(GoalDraft(id: "new-goal", kind: .createGoal, title: "旧身份的保存"))
        let identity = model.cacheIdentityKey
        let save = Task { await model.submitGoalDraft(id, identity: identity) }
        await api.waitForCreate()
        let persisted = try store.loadSnapshot()
        model.signOut()
        await api.releaseCreate()
        let succeeded = await save.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(model.goals.isEmpty)
        XCTAssertTrue(model.goalDrafts.isEmpty)
        XCTAssertEqual(try store.loadSnapshot(), persisted, "旧响应不能回写当前状态")
    }

    @MainActor
    func testNewServerIdentityIgnoresOldCacheDraftsAndLateGoalResponse() async throws {
        let oldAPI = try GoalScenarioAPI()
        let newAPI = try GoalScenarioAPI(deviceID: "device-2", goalID: "new-goal")
        let store = try GoalScenarioStore(snapshot: GoalScenarioValues.snapshot())
        let model = AppModel(serverURL: GoalScenarioValues.url, api: oldAPI,
            apiFactory: { url in url.host == "new-goals.invalid" ? newAPI : oldAPI },
            credentials: GoalScenarioCredentials(try GoalScenarioValues.session()), store: store)
        await model.bootstrap()
        await model.refreshGoals()
        model.beginGoalDraft(GoalDraft(id: "old-draft", kind: .editGoal, goalID: "goal-1", expectedRevision: 1, title: "旧身份输入"))
        await oldAPI.holdNextGoal()
        let oldRead = Task { await model.loadGoal("goal-1", force: true) }
        await oldAPI.waitForGoal()
        await model.pair(serverURL: URL(string: "https://new-goals.invalid")!, secret: "test-pair-secret", deviceName: "另一身份")
        defer { model.signOut() }
        XCTAssertEqual(model.session?.device.id, "device-2")
        XCTAssertTrue(model.goalDrafts.isEmpty)
        XCTAssertTrue(model.goals.isEmpty)
        await model.refreshGoals()
        await oldAPI.releaseGoal()
        await oldRead.value
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
        XCTAssertNil(model.goalDetails["goal-1"])
        XCTAssertEqual(try store.loadSnapshot()?.identityKey, "https://new-goals.invalid|device-2")
    }

    @MainActor
    func testRebaseStopsAfterOldGoalReadWhenIdentityChangesBeforeTaskRefresh() async throws {
        let (model, oldAPI, newAPI, store) = try await makeIdentitySwapModel()
        defer { model.signOut() }
        var draft = GoalDraft(id: "rebase-old-task", kind: .taskProgress, goalID: "goal-1", taskID: "task-1",
            expectedRevision: 1, title: "旧身份任务", note: "保留的输入")
        draft.state = .conflict
        let id = model.beginGoalDraft(draft)
        await oldAPI.holdNextGoal()
        let rebase = Task { @MainActor in await model.reviseGoalDraft(id, identity: model.cacheIdentityKey) }
        await oldAPI.waitForGoal()

        await pairNewIdentity(model)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        await oldAPI.releaseGoal()
        await rebase.value

        let newTaskReads = await newAPI.recordedGoalTaskReads()
        XCTAssertTrue(newTaskReads.isEmpty)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        XCTAssertTrue(model.goalDrafts.isEmpty)
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
        XCTAssertTrue(try store.loadSnapshot()?.goalCache.drafts.isEmpty == true)
    }

    @MainActor
    func testConflictRecoveryStopsAfterOldGoalReadWhenIdentityChangesBeforeTaskRefresh() async throws {
        let (model, oldAPI, newAPI, store) = try await makeIdentitySwapModel()
        defer { model.signOut() }
        await oldAPI.conflictNextTaskUpdate()
        let id = model.beginGoalDraft(GoalDraft(id: "conflict-old-task", kind: .taskProgress, goalID: "goal-1", taskID: "task-1",
            expectedRevision: 1, title: "旧身份任务", note: "保留的输入"))
        await oldAPI.holdNextGoal()
        let submit = Task { @MainActor in await model.submitGoalDraft(id, identity: model.cacheIdentityKey) }
        await oldAPI.waitForGoal()

        await pairNewIdentity(model)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        await oldAPI.releaseGoal()
        let submitResult = await submit.value
        XCTAssertFalse(submitResult)

        let newTaskReads = await newAPI.recordedGoalTaskReads()
        XCTAssertTrue(newTaskReads.isEmpty)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        XCTAssertTrue(model.goalDrafts.isEmpty)
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
        XCTAssertTrue(try store.loadSnapshot()?.goalCache.drafts.isEmpty == true)
    }

    @MainActor
    func testSuccessfulSubmitStopsAfterOldGoalReadWhenIdentityChangesBeforeTaskRefresh() async throws {
        let (model, oldAPI, newAPI, store) = try await makeIdentitySwapModel()
        defer { model.signOut() }
        let id = model.beginGoalDraft(GoalDraft(id: "success-old-task", kind: .taskProgress, goalID: "goal-1", taskID: "task-1",
            expectedRevision: 1, title: "旧身份任务", note: "成功的输入"))
        await oldAPI.holdNextGoal()
        let submit = Task { @MainActor in await model.submitGoalDraft(id, identity: model.cacheIdentityKey) }
        await oldAPI.waitForGoal()

        await pairNewIdentity(model)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        await oldAPI.releaseGoal()
        let submitResult = await submit.value
        XCTAssertFalse(submitResult)

        let newTaskReads = await newAPI.recordedGoalTaskReads()
        XCTAssertTrue(newTaskReads.isEmpty)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        XCTAssertTrue(model.goalDrafts.isEmpty)
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
        XCTAssertTrue(try store.loadSnapshot()?.goalCache.drafts.isEmpty == true)
    }

    @MainActor
    func testGoalScreenRefreshStopsAfterReconnectWhenIdentityChanges() async throws {
        let (model, oldAPI, newAPI, _) = try await makeIdentitySwapModel()
        defer { model.signOut() }
        await oldAPI.holdNextHealth()
        let refresh = Task { @MainActor in await model.refreshGoalData(goalID: "goal-1") }
        await oldAPI.waitForHealth()

        await pairNewIdentity(model)
        await oldAPI.releaseHealth()
        await refresh.value

        let goalReads = await newAPI.recordedGoalReads()
        XCTAssertTrue(goalReads.isEmpty)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
    }

    @MainActor
    func testGoalScreenRefreshStopsAfterGoalListWhenIdentityChanges() async throws {
        let (model, oldAPI, newAPI, _) = try await makeIdentitySwapModel()
        defer { model.signOut() }
        await oldAPI.holdNextGoalList()
        let refresh = Task { @MainActor in await model.refreshGoalData(goalID: "goal-1") }
        await oldAPI.waitForGoalList()

        await pairNewIdentity(model)
        await oldAPI.releaseGoalList()
        await refresh.value

        let goalReads = await newAPI.recordedGoalReads()
        XCTAssertTrue(goalReads.isEmpty)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
    }

    @MainActor
    func testTaskScreenRefreshStopsAfterGoalReadWhenIdentityChanges() async throws {
        let (model, oldAPI, newAPI, _) = try await makeIdentitySwapModel()
        defer { model.signOut() }
        await oldAPI.holdNextGoal()
        let refresh = Task { @MainActor in await model.refreshGoalData(goalID: "goal-1", taskID: "task-1") }
        await oldAPI.waitForGoal()

        await pairNewIdentity(model)
        await oldAPI.releaseGoal()
        await refresh.value

        let taskReads = await newAPI.recordedGoalTaskReads()
        XCTAssertTrue(taskReads.isEmpty)
        XCTAssertTrue(model.goalsOnline)
        XCTAssertNil(model.goalsError)
        XCTAssertEqual(model.goals.map(\.id), ["new-goal"])
    }

    @MainActor
    func testPendingQuestionRetryKeepsOriginalGoalAfterSelectionChanges() async throws {
        let api = try GoalScenarioAPI()
        await api.failQuestions(2)
        let (model, _) = try await makeModel(api)
        defer { model.signOut() }
        model.associateCurrentConversation(with: "goal-1")
        await model.send("还剩什么")
        let pending = try XCTUnwrap(model.pendingMessages.first)
        XCTAssertEqual(pending.goalID, "goal-1")
        model.associateCurrentConversation(with: "goal-2")
        await model.retryPending(pending)
        let requests = await api.recordedQuestions()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.goalID == "goal-1" && $0.request.clientRequestId == pending.clientRequestID && $0.request.text == pending.text })
        let ordinary = await api.recordedOrdinaryCount()
        XCTAssertEqual(ordinary, 0)
        XCTAssertTrue(model.pendingMessages.isEmpty)
        XCTAssertEqual(model.associatedGoalID, "goal-2")
        XCTAssertEqual(model.runRecords.first?.goalID, "goal-1")
    }

    @MainActor
    func testDisabledGoalQuestionsKeepPendingAndNeverDowngradeToOrdinaryChat() async throws {
        let api = try GoalScenarioAPI()
        await api.setQuestionsEnabled(false)
        let pending = PendingMessage(conversationID: "conv-1", clientRequestID: "pending-question", text: "原问题", createdAt: "now", goalID: "goal-1")
        let snapshot = try GoalScenarioValues.snapshot(pending: [pending])
        let (model, _) = try await makeModel(api, store: GoalScenarioStore(snapshot: snapshot))
        defer { model.signOut() }
        await model.retryPending(pending)
        XCTAssertEqual(model.pendingMessages, [pending])
        let questions = await api.recordedQuestions()
        let ordinary = await api.recordedOrdinaryCount()
        XCTAssertTrue(questions.isEmpty)
        XCTAssertEqual(ordinary, 0)
    }

    @MainActor
    func testAnswerContextStaysOriginalAfterLiveGoalUpdateAndRestart() async throws {
        let api = try GoalScenarioAPI()
        let (model, store) = try await makeModel(api)
        model.associateCurrentConversation(with: "goal-1")
        await model.send("现在的进展")
        let record = try XCTUnwrap(model.runRecords.first)
        let original = try XCTUnwrap(model.goalContexts[record.id])
        try await api.changeLiveGoalTitle("提问后已更新")
        await model.loadGoal("goal-1", force: true)
        await model.loadGoalContext(record.id)
        XCTAssertEqual(model.goalDetails["goal-1"]?.goal.title, "提问后已更新")
        XCTAssertEqual(model.goalContexts[record.id], original)
        model.signOut()
        let (restored, _) = try await makeModel(api, store: store)
        defer { restored.signOut() }
        await restored.loadGoalContext(record.id)
        XCTAssertEqual(restored.goalContexts[record.id], original)
        let reads = await api.contextReadCount()
        XCTAssertEqual(reads, 1, "固定缓存可离线展示，不能点击时改读最新目标")
    }

    @MainActor
    func testProgressRetryUsesOriginalPayloadAndCreatesOneHistoryEntry() async throws {
        let api = try GoalScenarioAPI()
        await api.loseNextTaskAck()
        let (model, _) = try await makeModel(api)
        defer { model.signOut() }
        let id = model.beginGoalDraft(GoalDraft(id: "progress", kind: .taskProgress, goalID: "goal-1", taskID: "task-1",
            expectedRevision: 1, title: "任务", note: "一次真实进展"))
        let first = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertFalse(first)
        let original = model.goalDrafts[id]?.mutation
        await model.refreshGoals()
        let second = await model.submitGoalDraft(id, identity: model.cacheIdentityKey)
        XCTAssertTrue(second)
        let commands = await api.recordedTaskCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.first, commands.last)
        XCTAssertEqual(original?.commandID, commands.last?.commandId)
        let count = await api.progressCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.goalTaskDetails["task-1"]?.progressEntries.first?.note, "一次真实进展")
    }

    @MainActor
    func testClosingGoalActionThenChoosingAnotherSubmitsOnlyNewSelection() async throws {
        let api = try GoalScenarioAPI()
        let (model, _) = try await makeModel(api)
        defer { model.signOut() }
        let goal = try GoalScenarioValues.goal()
        let completeID = model.beginGoalDraft(GoalDraft.forGoalAction(goal, action: .complete))
        // 关闭只保留草稿，再从菜单选择另一动作。
        let archiveID = model.beginGoalDraft(GoalDraft.forGoalAction(goal, action: .archive))
        XCTAssertNotEqual(completeID, archiveID)
        let result = await model.submitGoalDraft(archiveID, identity: model.cacheIdentityKey)
        XCTAssertTrue(result)
        let commands = await api.recordedGoalCommands()
        XCTAssertEqual(commands.map(\.action), [.archive])
        XCTAssertEqual(model.goalDrafts[completeID]?.goalAction, .complete)
    }

    @MainActor
    func testClosingTaskStatusThenChoosingBlockedKeepsBothDraftsAndSubmitsBlocked() async throws {
        let api = try GoalScenarioAPI()
        let (model, _) = try await makeModel(api)
        defer { model.signOut() }
        let task = try GoalScenarioValues.task()
        let progressingID = model.beginGoalDraft(GoalDraft.forTaskStatus(task, status: .inProgress))
        let blockedID = model.beginGoalDraft(GoalDraft.forTaskStatus(task, status: .blocked))
        XCTAssertNotEqual(progressingID, blockedID)
        var blocked = try XCTUnwrap(model.goalDrafts[blockedID])
        blocked.note = "等待依赖"
        model.updateGoalDraft(blocked, identity: model.cacheIdentityKey)
        let result = await model.submitGoalDraft(blockedID, identity: model.cacheIdentityKey)
        XCTAssertTrue(result)
        let commands = await api.recordedTaskCommands()
        XCTAssertEqual(commands.map(\.status), [.blocked])
        XCTAssertEqual(commands.first?.note, "等待依赖")
        XCTAssertEqual(model.goalDrafts[progressingID]?.status, .inProgress)
    }

    @MainActor
    func testFailedLocalEditShowsStorageErrorAndRestartOnlyRestoresSavedInput() async throws {
        let api = try GoalScenarioAPI()
        let (model, store) = try await makeModel(api)
        let id = model.beginGoalDraft(GoalDraft(id: "local-edit", kind: .createGoal, title: "已保存的输入"))
        store.setFailWrites(true)
        var edited = try XCTUnwrap(model.goalDrafts[id])
        edited.title = "尚未存盘的输入"
        model.updateGoalDraft(edited, identity: model.cacheIdentityKey)
        XCTAssertNotNil(model.goalDraftStorageError, "表单与目标列表必须能显示本机保存失败")
        XCTAssertEqual(model.goalDrafts[id]?.title, edited.title)
        XCTAssertEqual(try store.loadSnapshot()?.goalCache.drafts.first?.title, "已保存的输入")
        model.signOut()
        store.setFailWrites(false)
        let (restored, _) = try await makeModel(api, store: store)
        defer { restored.signOut() }
        XCTAssertEqual(restored.goalDrafts[id]?.title, "已保存的输入")
        let requests = await api.recordedCreates()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testLocalStorageRetryPersistsLatestDraftBeforeRestartWithoutCloudWrite() async throws {
        let api = try GoalScenarioAPI()
        let (model, store) = try await makeModel(api)
        let id = model.beginGoalDraft(GoalDraft(id: "local-retry", kind: .createGoal, title: "最初输入"))
        store.setFailWrites(true)
        var edited = try XCTUnwrap(model.goalDrafts[id])
        edited.title = "重试后保留的输入"
        model.updateGoalDraft(edited, identity: model.cacheIdentityKey)
        XCTAssertNotNil(model.goalDraftStorageError)
        store.setFailWrites(false)
        XCTAssertTrue(model.persistGoalDraftsLocally(identity: model.cacheIdentityKey))
        XCTAssertNil(model.goalDraftStorageError)
        model.signOut()
        let (restored, _) = try await makeModel(api, store: store)
        defer { restored.signOut() }
        XCTAssertEqual(restored.goalDrafts[id]?.title, edited.title)
        let requests = await api.recordedCreates()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    private func makeIdentitySwapModel() async throws -> (AppModel, GoalScenarioAPI, GoalScenarioAPI, GoalScenarioStore) {
        let oldAPI = try GoalScenarioAPI()
        let newAPI = try GoalScenarioAPI(deviceID: "device-2", goalID: "new-goal")
        await newAPI.setRejectGoalTaskReads(true)
        let store = try GoalScenarioStore(snapshot: GoalScenarioValues.snapshot())
        let model = AppModel(serverURL: GoalScenarioValues.url, api: oldAPI,
            apiFactory: { url in url.host == "new-goals.invalid" ? newAPI : oldAPI },
            credentials: GoalScenarioCredentials(try GoalScenarioValues.session()), store: store)
        await model.bootstrap()
        await model.refreshGoals()
        return (model, oldAPI, newAPI, store)
    }

    @MainActor
    private func pairNewIdentity(_ model: AppModel) async {
        await model.pair(serverURL: URL(string: "https://new-goals.invalid")!, secret: "test-pair-secret", deviceName: "另一身份")
        await model.refreshGoals()
    }

    @MainActor
    private func makeModel(_ api: GoalScenarioAPI, store: GoalScenarioStore? = nil, refreshGoals: Bool = true) async throws -> (AppModel, GoalScenarioStore) {
        let cache = try store ?? GoalScenarioStore(snapshot: GoalScenarioValues.snapshot())
        let model = AppModel(serverURL: GoalScenarioValues.url, api: api,
            credentials: GoalScenarioCredentials(try GoalScenarioValues.session()), store: cache)
        await model.bootstrap()
        if refreshGoals { await model.refreshGoals() }
        return (model, cache)
    }
}

private struct RecordedGoalQuestion: Sendable { let goalID: String; let request: GoalQuestionRequest }

private actor GoalScenarioAPI: POSAPI {
    private let auth: AuthSession
    private var goalRecords: [String: Goal]
    private var taskRecord: GoalTask
    private var entries: [GoalProgressEntry] = []
    private var creates: [CreateGoalRequest] = []
    private var goalCommands: [GoalCommand] = []
    private var taskCommands: [GoalTaskCommand] = []
    private var questions: [RecordedGoalQuestion] = []
    private var ordinaryCount = 0
    private var createReceipts: [String: Goal] = [:]
    private var taskReceipts: [String: GoalTask] = [:]
    private var contexts: [String: GoalQuestionContext] = [:]
    private var contextReads = 0
    private var loseCreate = false
    private var loseTask = false
    private var conflictGoal = false
    private var questionsEnabled = true
    private var questionFailures = 0
    private var healthOffline = false
    private var holdHealth = false
    private var healthGate: CheckedContinuation<Void, Never>?
    private var healthWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdGoalList = false
    private var goalListGate: CheckedContinuation<Void, Never>?
    private var goalListWaiters: [CheckedContinuation<Void, Never>] = []
    private var goalReads: [String] = []
    private var holdCreate = false
    private var createGate: CheckedContinuation<Void, Never>?
    private var createWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdGoal = false
    private var goalGate: CheckedContinuation<Void, Never>?
    private var goalWaiters: [CheckedContinuation<Void, Never>] = []
    private var rejectGoalTaskReadsOnRead = false
    private var goalTaskReads: [String] = []
    private var conflictTask = false

    init(deviceID: String = "device-1", goalID: String = "goal-1") throws {
        auth = try GoalScenarioValues.session(deviceID: deviceID)
        let goal = try GoalScenarioValues.goal(id: goalID)
        goalRecords = [goalID: goal]
        if goalID == "goal-1" { goalRecords["goal-2"] = try GoalScenarioValues.goal(id: "goal-2") }
        taskRecord = try GoalScenarioValues.task(goalID: goalID)
    }
    func recordedCreates() -> [CreateGoalRequest] { creates }
    func recordedGoalCommands() -> [GoalCommand] { goalCommands }
    func recordedTaskCommands() -> [GoalTaskCommand] { taskCommands }
    func recordedQuestions() -> [RecordedGoalQuestion] { questions }
    func recordedOrdinaryCount() -> Int { ordinaryCount }
    func createdGoalCount() -> Int { createReceipts.count }
    func contextReadCount() -> Int { contextReads }
    func progressCount() -> Int { entries.count }
    func loseNextCreateAck() { loseCreate = true }
    func loseNextTaskAck() { loseTask = true }
    func conflictNextGoalUpdate() { conflictGoal = true }
    func conflictNextTaskUpdate() { conflictTask = true }
    func setRejectGoalTaskReads(_ value: Bool) { rejectGoalTaskReadsOnRead = value }
    func recordedGoalTaskReads() -> [String] { goalTaskReads }
    func setQuestionsEnabled(_ value: Bool) { questionsEnabled = value }
    func failQuestions(_ count: Int) { questionFailures = count }
    func setHealthOffline(_ value: Bool) { healthOffline = value }
    func recordedGoalReads() -> [String] { goalReads }
    func holdNextHealth() { holdHealth = true }
    func waitForHealth() async {
        if healthGate != nil { return }
        await withCheckedContinuation { healthWaiters.append($0) }
    }
    func releaseHealth() { healthGate?.resume(); healthGate = nil }
    func holdNextGoalList() { holdGoalList = true }
    func waitForGoalList() async {
        if goalListGate != nil { return }
        await withCheckedContinuation { goalListWaiters.append($0) }
    }
    func releaseGoalList() { goalListGate?.resume(); goalListGate = nil }
    func changeLiveGoalTitle(_ title: String) throws {
        goalRecords["goal-1"] = try GoalScenarioValues.goal(title: title, revision: 2)
    }
    func holdNextCreate() { holdCreate = true }
    func waitForCreate() async {
        if createGate != nil { return }
        await withCheckedContinuation { createWaiters.append($0) }
    }
    func releaseCreate() { holdCreate = false; createGate?.resume(); createGate = nil }
    func holdNextGoal() { holdGoal = true }
    func waitForGoal() async {
        if goalGate != nil { return }
        await withCheckedContinuation { goalWaiters.append($0) }
    }
    func releaseGoal() { goalGate?.resume(); goalGate = nil }

    func health() async throws -> HealthResponse {
        if holdHealth {
            holdHealth = false
            await withCheckedContinuation { continuation in
                healthGate = continuation
                for waiter in healthWaiters { waiter.resume() }; healthWaiters = []
            }
        }
        if healthOffline { throw POSAPIError.transport("offline") }
        return try GoalScenarioValues.decode(["ok": true, "service": "personal-os-cloud", "protocolVersion": 2])
    }
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession { auth }
    func me(_ session: AuthSession) async throws -> DeviceInfo { auth.device }
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation { try GoalScenarioValues.conversation() }
    func conversations(_ session: AuthSession) async throws -> [Conversation] { try [GoalScenarioValues.conversation()] }
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage {
        if waitSeconds > 0 { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return try GoalScenarioValues.decode(["messages": [], "nextCursor": after])
    }
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck {
        ordinaryCount += 1
        return try ack(request.clientRequestID, request.text, goalID: nil)
    }
    func run(_ session: AuthSession, runID: String) async throws -> Run {
        try GoalScenarioValues.decode(["id": runID, "conversationId": "conv-1", "messageId": "message-1", "status": "completed", "goalId": contexts[runID]?.goalId as Any? ?? NSNull()])
    }
    func cancelRun(_ session: AuthSession, runID: String) async throws -> Run { try await run(session, runID: runID) }
    func capabilities(_ session: AuthSession) async throws -> POSCapabilities {
        POSCapabilities(goalsTasksVersion: 1, goalQuestionsVersion: questionsEnabled ? 1 : 0)
    }
    func goals(_ session: AuthSession, status: GoalStatus) async throws -> [Goal] {
        let captured = goalRecords.values.filter { $0.status == status }.sorted { $0.id < $1.id }
        if holdGoalList && status == .active {
            holdGoalList = false
            await withCheckedContinuation { continuation in
                goalListGate = continuation
                for waiter in goalListWaiters { waiter.resume() }; goalListWaiters = []
            }
        }
        return captured
    }
    func goal(_ session: AuthSession, goalID: String) async throws -> GoalDetail {
        goalReads.append(goalID)
        guard let goal = goalRecords[goalID] else { throw POSAPIError.server(status: 404, code: "not_found", message: "missing") }
        let captured: GoalDetail = try GoalScenarioValues.decode(["goal": GoalScenarioValues.object(goal),
            "tasks": goalID == taskRecord.goalId ? [GoalScenarioValues.object(taskRecord)] : [],
            "summary": GoalScenarioValues.summary, "viewRevision": goal.revision + taskRecord.revision, "asOf": "2026-11-26T01:00:00Z"])
        if holdGoal {
            holdGoal = false
            await withCheckedContinuation { continuation in
                goalGate = continuation
                for waiter in goalWaiters { waiter.resume() }; goalWaiters = []
            }
        }
        return captured
    }
    func createGoal(_ session: AuthSession, _ request: CreateGoalRequest) async throws -> Goal {
        creates.append(request)
        if holdCreate {
            await withCheckedContinuation { continuation in
                createGate = continuation
                for waiter in createWaiters { waiter.resume() }; createWaiters = []
            }
        }
        if let prior = createReceipts[request.commandId] { return prior }
        let goal = try GoalScenarioValues.goal(id: "created-goal", title: request.title)
        createReceipts[request.commandId] = goal
        goalRecords[goal.id] = goal
        if loseCreate { loseCreate = false; throw POSAPIError.transport("ack lost after commit") }
        return goal
    }
    func updateGoal(_ session: AuthSession, goalID: String, _ command: GoalCommand) async throws -> Goal {
        goalCommands.append(command)
        if conflictGoal {
            conflictGoal = false
            goalRecords[goalID] = try GoalScenarioValues.goal(id: goalID, title: "另一设备更新", revision: 2)
            throw POSAPIError.conflict("revision changed")
        }
        let goal = try GoalScenarioValues.goal(id: goalID, title: command.title ?? "目标", revision: command.expectedRevision + 1)
        goalRecords[goalID] = goal
        return goal
    }
    func createGoalTask(_ session: AuthSession, goalID: String, _ request: CreateGoalTaskRequest) async throws -> GoalTask { taskRecord }
    func updateGoalTask(_ session: AuthSession, taskID: String, _ command: GoalTaskCommand) async throws -> GoalTask {
        taskCommands.append(command)
        if conflictTask {
            conflictTask = false
            throw POSAPIError.conflict("task revision changed")
        }
        if let prior = taskReceipts[command.commandId] { return prior }
        taskRecord = try GoalScenarioValues.task(revision: taskRecord.revision + 1)
        let entry: GoalProgressEntry = try GoalScenarioValues.decode(["id": "progress-1", "taskId": taskID, "actorDeviceId": auth.device.id,
            "kind": "note", "note": command.note ?? "", "fromStatus": NSNull(), "toStatus": NSNull(), "createdAt": "2026-11-26T01:00:00Z"])
        entries.append(entry)
        taskReceipts[command.commandId] = taskRecord
        if loseTask { loseTask = false; throw POSAPIError.transport("ack lost after progress commit") }
        return taskRecord
    }
    func goalTask(_ session: AuthSession, taskID: String) async throws -> GoalTaskDetail {
        goalTaskReads.append(taskID)
        if rejectGoalTaskReadsOnRead {
            throw POSAPIError.server(status: 404, code: "not_found", message: "stale task ID")
        }
        return try GoalScenarioValues.decode(["task": GoalScenarioValues.object(taskRecord), "progressEntries": entries.map { try GoalScenarioValues.object($0) },
            "nextCursor": NSNull(), "progressRevision": taskRecord.revision])
    }
    func askGoal(_ session: AuthSession, goalID: String, _ request: GoalQuestionRequest) async throws -> SendMessageAck {
        questions.append(RecordedGoalQuestion(goalID: goalID, request: request))
        if questionFailures > 0 { questionFailures -= 1; throw POSAPIError.transport("question ack lost") }
        let result = try ack(request.clientRequestId, request.text, goalID: goalID)
        if contexts[result.run.id] == nil {
            guard let goal = goalRecords[goalID] else { throw POSAPIError.decoding("missing goal") }
            contexts[result.run.id] = try GoalScenarioValues.decode(["runId": result.run.id, "goalId": goalID,
                "goal": GoalScenarioValues.object(goal), "viewRevision": goal.revision, "asOf": "2026-11-26T00:00:00Z",
                "summary": GoalScenarioValues.summary, "includedTasks": [],
                "omissions": ["taskCount": 1, "progressEntryCount": 0, "truncatedFields": [], "reasons": ["context_size"]]])
        }
        return result
    }
    func goalContext(_ session: AuthSession, runID: String) async throws -> GoalQuestionContext? { contextReads += 1; return contexts[runID] }
    private func ack(_ key: String, _ text: String, goalID: String?) throws -> SendMessageAck {
        try GoalScenarioValues.decode(["message": ["id": "message-1", "conversationId": "conv-1", "clientRequestId": key,
            "seq": 1, "role": "user", "text": text, "createdAt": "2026-11-26T00:00:00Z"],
            "run": ["id": "run-1", "conversationId": "conv-1", "messageId": "message-1", "status": "completed", "goalId": goalID as Any? ?? NSNull()], "created": true])
    }
}

private enum GoalScenarioValues {
    static let url = URL(string: "https://goals.invalid")!
    static var summary: [String: Any] {
        ["completedTasks": 0, "todoTasks": 1, "inProgressTasks": 0, "activeTasks": 1,
         "blockedTasks": 0, "canceledTasks": 0, "completionPercent": 0, "latestUpdatedAt": "2026-11-26T00:00:00Z"]
    }
    static func decode<T: Decodable>(_ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    static func session(deviceID: String = "device-1") throws -> AuthSession {
        try decode(["token": "test-token", "device": ["id": deviceID, "name": "iPhone", "role": "client", "createdAt": "now"]])
    }
    static func conversation() throws -> Conversation {
        try decode(["id": "conv-1", "ownerId": "default", "title": "聊天", "createdAt": "now", "updatedAt": "now"])
    }
    static func goal(id: String = "goal-1", title: String = "目标", revision: Int = 1) throws -> Goal {
        try decode(["id": id, "ownerId": "default", "title": title, "description": NSNull(), "successCriteria": NSNull(),
            "targetDate": NSNull(), "status": "active", "archivedFromStatus": NSNull(), "revision": revision,
            "createdAt": "2026-11-26T00:00:00Z", "updatedAt": "2026-11-26T01:00:00Z"])
    }
    static func task(goalID: String = "goal-1", revision: Int = 1) throws -> GoalTask {
        try decode(["id": "task-1", "goalId": goalID, "title": "任务", "status": "todo", "revision": revision,
            "createdAt": "2026-11-26T00:00:00Z", "updatedAt": "2026-11-26T01:00:00Z"])
    }
    static func snapshot(pending: [PendingMessage] = []) throws -> CachedSnapshot {
        CachedSnapshot(savedAt: "2026-11-25T00:00:00Z", conversations: try [conversation()], selectedConversationID: "conv-1",
            conversationStates: [ConversationSnapshot(conversationID: "conv-1", messages: [], cursor: 0)], pendingMessages: pending,
            goals: try [goal()], goalCache: GoalCache(lastSyncedAt: "2026-11-25T00:00:00Z"))
    }
}

private final class GoalScenarioCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession?
    init(_ session: AuthSession) { value = session }
    func load() throws -> AuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: AuthSession) throws { lock.lock(); defer { lock.unlock() }; value = session }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

private final class GoalScenarioStore: SnapshotStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CachedSnapshot?
    private var failWrites = false
    init(snapshot: CachedSnapshot? = nil) { self.snapshot = snapshot }
    func setFailWrites(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failWrites = value }
    func loadSnapshot() throws -> CachedSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
    func saveSnapshot(_ snapshot: CachedSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw POSAPIError.transport("disk full") }
        self.snapshot = try JSONDecoder().decode(CachedSnapshot.self, from: JSONEncoder().encode(snapshot))
    }
}
