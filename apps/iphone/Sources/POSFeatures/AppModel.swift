import Foundation
import Combine
import POSCore

/// v2 聊天与可选目标状态；凭据与离线数据由 POSCore 存储。
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var phase: AppPhase = .signedOut
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var conversations: [Conversation] = []
    @Published public private(set) var selectedConversationID: String?
    @Published public private(set) var pendingMessages: [PendingMessage] = []
    @Published public private(set) var runRecords: [RunRecord] = []
    @Published public private(set) var cancelingRunIDs: Set<String> = []
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var connection: ConnectionState = .unknown
    @Published public private(set) var serverModel: String?
    @Published private var hasCurrentModel = false
    @Published public private(set) var serverURL: URL
    @Published public private(set) var session: AuthSession?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isSending = false
    @Published public private(set) var isCreatingConversation = false
    @Published public private(set) var needsRefresh = false
    @Published public private(set) var notice: String?
    @Published public var draft = ""
    @Published public private(set) var goals: [Goal] = []
    @Published public private(set) var goalDetails: [String: GoalDetail] = [:]
    @Published public private(set) var goalsCapabilities: POSCapabilities?
    @Published public private(set) var goalsError: String?
    @Published public private(set) var isLoadingGoals = false
    @Published public private(set) var loadingGoalIDs: Set<String> = []
    @Published public private(set) var isCreatingGoal = false
    @Published public private(set) var pendingGoalActions: Set<String> = []
    @Published public private(set) var conversationGoalIDs: [String: String] = [:]
    @Published public private(set) var goalTaskDetails: [String: GoalTaskDetail] = [:]
    @Published public private(set) var goalDrafts: [String: GoalDraft] = [:]
    @Published public private(set) var goalDraftStorageError: String?
    @Published public private(set) var goalContexts: [String: GoalQuestionContext] = [:]
    @Published public private(set) var goalContextErrors: [String: String] = [:]
    @Published public private(set) var loadingGoalContextIDs: Set<String> = []
    @Published public private(set) var loadingGoalTaskIDs: Set<String> = []
    @Published public private(set) var goalsLastSyncedAt: String?
    @Published public private(set) var goalsOnline = false
    @Published public var selectedTab = 0

    // 仅让未展示的旧页面继续编译。v2 不读取或显示旧任务/上下文。
    public let tasks: [TaskSummary] = []
    public let context: ContextSnapshot? = nil
    public let presence: Presence? = nil
    public let pendingTaskActions: Set<String> = []
    public var pendingDecisionCount: Int { 0 }

    private var api: (any POSAPI)?
    private let apiFactory: ((URL) -> (any POSAPI))?
    private let credentials: any CredentialStore
    private let injectedStore: (any SnapshotStore)?
    private var store: (any SnapshotStore)?
    private var conversationStates: [String: ConversationSnapshot] = [:]
    private var goalDetailGenerations: [String: Int] = [:]
    private var goalTaskGenerations: [String: Int] = [:]
    private var goalsPollingTask: Task<Void, Never>?
    private var goalsPollingGeneration = 0
    private var goalsTabActive = false
    private var visibleGoalID: String?
    private var visibleGoalTaskID: String?
    /// 升级前的全局时间线/任务/上下文保留在快照中，不混入任何 v2 会话。
    private var restoredSnapshot: CachedSnapshot?
    private var cursor = 0
    private var syncEngine: SyncEngine?
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    private var runPollingTask: Task<Void, Never>?
    private var runPollingGeneration = 0
    private var isApplicationActive = true
    private var identityGeneration = 0
    private var hasBootstrapped = false
    private var hasValidatedServer = false
    private static let serverURLDefaultsKey = "pos.serverURL"

    public init(serverURL: URL, api: POSAPI? = nil,
                apiFactory: ((URL) -> (any POSAPI))? = nil,
                credentials: CredentialStore = KeychainCredentialStore(), store: SnapshotStore? = nil) {
        self.serverURL = serverURL
        self.api = api
        self.apiFactory = apiFactory
        self.credentials = credentials
        self.injectedStore = store
        self.store = store
    }

    public var deviceName: String { session?.device.name ?? "" }
    public var modelDisplayName: String {
        guard let serverModel else { return "服务器未提供型号" }
        return hasCurrentModel && connection.isOnline && phase.isReady
            ? serverModel : "\(serverModel)（上次连接）"
    }
    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }
    public var currentPendingMessages: [PendingMessage] {
        pendingMessages.filter { $0.conversationID == selectedConversationID }
    }
    public var currentRunRecords: [RunRecord] {
        runRecords.filter { $0.conversationID == selectedConversationID }
    }

    public var canEditGoals: Bool {
        phase.isReady && hasValidatedServer && connection.isOnline && goalsOnline && goalsCapabilities?.supportsGoals == true
    }
    public var cacheIdentityKey: String { "\(serverURL.absoluteString)|\(session?.device.id ?? "")" }
    public var associatedGoalID: String? { selectedConversationID.flatMap { conversationGoalIDs[$0] } }
    public var supportsGoalQuestions: Bool { goalsCapabilities?.supportsGoalQuestions == true }
    public var associatedGoal: Goal? {
        guard let conversationID = selectedConversationID, let goalID = conversationGoalIDs[conversationID] else { return nil }
        return goals.first { $0.id == goalID } ?? goalDetails[goalID]?.goal
    }

    public func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            guard let restored = try credentials.load() else { return }
            session = restored
            if let saved = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey),
               let url = URL(string: saved), url.host != nil,
               url.scheme == "http" || url.scheme == "https" { serverURL = url }
            if api == nil { api = apiFactory?(serverURL) }
            hydrateFromSnapshot()
            phase = .ready
            await refresh()
            if phase.isReady {
                startSync()
                startRunPolling()
            }
        } catch {
            notice = "读取本机配对凭据失败，请重新配对"
        }
    }

    public func pair(serverURL: URL, secret: String, deviceName: String) async {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { phase = .failed("请输入配对密钥"); return }
        guard serverURL.host != nil, serverURL.scheme == "http" || serverURL.scheme == "https" else {
            phase = .failed("服务器地址无效"); return
        }
        // 工厂按本次地址重建，重新配对也必须使用新填写的服务器。
        guard let pairedAPI = apiFactory?(serverURL) ?? api else {
            phase = .failed("缺少网络实现"); return
        }
        guard !phase.isPairing else { return }
        let canRestoreSession = phase.isReady && session != nil
        identityGeneration += 1
        let generation = identityGeneration
        serverModel = nil
        hasCurrentModel = false
        stopSync()
        stopRunPolling()
        cancelingRunIDs = []
        isRefreshing = false
        isSending = false
        isCreatingConversation = false
        resetGoalRequests()
        phase = .pairing
        notice = nil
        do {
            _ = try await pairedAPI.health()
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let paired = try await pairedAPI.pair(secret: secret, PairRequest(name: name.isEmpty ? "iPhone" : name))
            guard generation == identityGeneration else { return }
            guard paired.device.role == "client" else { throw POSAPIError.decoding("需要 client 设备") }
            stopSync()
            api = pairedAPI
            self.serverURL = serverURL
            session = paired
            resetChat()
            store = injectedStore
            do { try credentials.save(paired) }
            catch { notice = "配对成功，但凭据未能写入 Keychain：下次启动需要重新配对" }
            UserDefaults.standard.set(serverURL.absoluteString, forKey: Self.serverURLDefaultsKey)
            hydrateFromSnapshot()
            phase = .ready
            await refresh()
            if phase.isReady {
                startSync()
                startRunPolling()
            }
        } catch {
            guard generation == identityGeneration else { return }
            let detail = POSCoreBridge.pairFailureMessage(error: error)
            if canRestoreSession {
                phase = .ready
                notice = detail
                startSync()
                startRunPolling()
            } else { phase = .failed(detail) }
        }
    }

    public func signOut() {
        stopSync()
        stopRunPolling()
        stopGoalsPolling()
        identityGeneration += 1
        do { try credentials.clear(); notice = nil }
        catch { notice = "本机凭据清除失败" }
        UserDefaults.standard.removeObject(forKey: Self.serverURLDefaultsKey)
        if apiFactory != nil { api = nil }
        session = nil
        store = injectedStore
        resetChat()
        isRefreshing = false
        isSending = false
        isCreatingConversation = false
        connection = .unknown
        phase = .signedOut
    }

    private func resetChat() {
        hasValidatedServer = false
        serverModel = nil
        hasCurrentModel = false
        messages = []
        conversations = []
        selectedConversationID = nil
        pendingMessages = []
        runRecords = []
        cancelingRunIDs = []
        conversationStates = [:]
        goals = []
        goalDetails = [:]
        goalTaskDetails = [:]
        goalDrafts = [:]
        goalDraftStorageError = nil
        goalContexts = [:]
        goalsLastSyncedAt = nil
        goalsTabActive = false
        visibleGoalID = nil
        visibleGoalTaskID = nil
        selectedTab = 0
        conversationGoalIDs = [:]
        resetGoalRequests()
        restoredSnapshot = nil
        cursor = 0
        draft = ""
        needsRefresh = false
        lastSyncedAt = nil
        isRefreshing = false
        isSending = false
        isCreatingConversation = false
    }

    /// 刷新设备身份与会话列表；消息仍从已保存的 after 增量读取。
    public func refresh() async {
        guard phase.isReady, !isRefreshing, let api, let session else { return }
        let generation = identityGeneration
        isRefreshing = true
        hasCurrentModel = false
        defer {
            if generation == identityGeneration {
                isRefreshing = false
                // 回前台时可能仍在等待这次刷新；结束后补回被后台暂停的轮询。
                if syncTask == nil { startSync() }
                if runPollingTask == nil { startRunPolling() }
                if goalsPollingTask == nil { startGoalsPolling() }
            }
        }
        do {
            let health = try await api.health()
            guard generation == identityGeneration else { return }
            hasValidatedServer = true
            let device = try await api.me(session)
            guard generation == identityGeneration else { return }
            guard device.role == "client", device.id == session.device.id else { throw POSAPIError.unauthorized }
            let model = health.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            serverModel = model?.isEmpty == false ? model : nil
            let list = try await api.conversations(session)
            guard generation == identityGeneration else { return }
            var byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            for conversation in list { byID[conversation.id] = conversation }
            conversations = byID.values.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
            if selectedConversationID == nil, let first = list.first {
                selectConversation(first.id)
            }
            if let id = selectedConversationID {
                let after = cursor
                let page = try await api.messages(session, conversationID: id, after: after, waitSeconds: 0)
                guard generation == identityGeneration else { return }
                apply(page.messages, to: id)
                // 只推进本次请求对应会话的游标；切换后的会话不受影响。
                updateCursor(page.nextCursor, conversationID: id)
            }
            guard generation == identityGeneration else { return }
            connection = .online
            hasCurrentModel = true
            lastSyncedAt = Date()
            needsRefresh = false
            persistSnapshot()
        } catch {
            guard generation == identityGeneration else { return }
            handle(error)
        }
    }

    public func createConversation(title: String? = nil) async {
        guard phase.isReady, !isCreatingConversation, let api, let session else { return }
        guard hasValidatedServer else { notice = "请先连接到兼容的服务器后创建会话"; return }
        let generation = identityGeneration
        isCreatingConversation = true
        defer { if generation == identityGeneration { isCreatingConversation = false } }
        do {
            let conversation = try await api.createConversation(session, title: title)
            guard generation == identityGeneration else { return }
            conversations.removeAll { $0.id == conversation.id }
            conversations.insert(conversation, at: 0)
            selectConversation(conversation.id)
            connection = .online
        } catch {
            guard generation == identityGeneration else { return }
            handle(error)
        }
    }

    public func selectConversation(_ id: String) {
        guard conversations.contains(where: { $0.id == id }), selectedConversationID != id else { return }
        saveCurrentConversation()
        stopSync()
        stopRunPolling()
        selectedConversationID = id
        messages = conversationStates[id]?.messages ?? []
        cursor = conversationStates[id]?.cursor ?? 0
        draft = ""
        persistSnapshot()
        startSync()
        startRunPolling()
    }

    public func reconnect() async {
        guard phase.isReady, !isRefreshing else { return }
        connection = .unknown
        stopSync()
        stopRunPolling()
        await refresh()
        if phase.isReady {
            startSync()
            startRunPolling()
        }
    }

    /// 暂停本机轮询不会取消云端运行；回到前台重新验证连接并恢复已知运行。
    public func setApplicationActive(_ active: Bool) async {
        isApplicationActive = active
        if active {
            await reconnect()
            await refreshVisibleGoals()
            startGoalsPolling()
        } else {
            stopGoalsPolling()
            stopSync()
            stopRunPolling()
        }
    }

    /// 先保存待发消息，再提交。失败不生成新键，重启后仍可明确重试。
    public func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase.isReady, !isSending else { return }
        guard let id = selectedConversationID else { notice = "请先创建或选择会话"; draft = text; return }
        guard api != nil, session != nil else { notice = "缺少网络实现，暂时无法发送"; draft = text; return }
        // 普通发送表示新的用户意图；只有明确重试才复用已有请求键。
        let pending = PendingMessage(conversationID: id, text: text, createdAt: POSDate.isoString(Date()), goalID: conversationGoalIDs[id])
        pendingMessages.append(pending)
        guard persistSnapshot() else {
            pendingMessages.removeAll { $0.id == pending.id }
            draft = text
            return
        }
        await sendPending(pending)
    }

    public func retryPending(_ pending: PendingMessage) async {
        guard pendingMessages.contains(where: { $0.id == pending.id }) else { return }
        await sendPending(pending)
    }

    private func sendPending(_ pending: PendingMessage) async {
        guard phase.isReady, !isSending, let api, let session else { return }
        guard hasValidatedServer else { notice = "服务器连接尚未验证，消息已保留待发"; return }
        let generation = identityGeneration
        isSending = true
        defer { if generation == identityGeneration { isSending = false } }
        if pending.goalID != nil {
            if goalsCapabilities == nil { await refreshGoals() }
            guard generation == identityGeneration else { return }
            guard supportsGoalQuestions else {
                notice = "当前服务器未启用目标问答；已保留原目标与待发消息，恢复能力后可重试"
                return
            }
        }
        for attempt in 0..<2 {
            do {
                let ack: SendMessageAck
                if let goalID = pending.goalID {
                    ack = try await api.askGoal(session, goalID: goalID, GoalQuestionRequest(
                        conversationID: pending.conversationID, clientRequestID: pending.clientRequestID, text: pending.text))
                } else {
                    ack = try await api.sendMessage(session, conversationID: pending.conversationID, pending.request)
                }
                guard generation == identityGeneration else { return }
                // 同时保存消息和运行回执，保留确认丢失时恢复运行所需的原键。
                try recordRun(ack.run)
                apply([ack.message], to: pending.conversationID)
                // ack 的 seq 可能跨过未读取的 assistant 消息，不能用 ack 推进 polling cursor。
                connection = .online
                lastSyncedAt = Date()
                notice = nil
                persistSnapshot()
                startRunPolling()
                if pending.goalID != nil { await loadGoalContext(ack.run.id) }
                return
            } catch {
                guard generation == identityGeneration else { return }
                let failure = POSCoreBridge.apiError(from: error)
                if attempt == 0 {
                    switch failure {
                    case .transport: continue
                    case .server(let status, _, _) where status >= 500: continue
                    default: break
                    }
                }
                handle(failure)
                notice = "消息发送结果未确认；已保留原幂等键，可点待发消息重试"
                if case .conflict = failure { await refresh() }
                return
            }
        }
    }

    /// 只查询本机保存过回执的运行；冻结 v2 没有按会话列出运行的接口。
    public func refreshRunStates() async {
        guard phase.isReady, hasValidatedServer, isApplicationActive,
              let api, let session, let conversationID = selectedConversationID else { return }
        let identity = identityGeneration
        let generation = runPollingGeneration
        let active = currentRunRecords.filter { !$0.status.isTerminal }
        for record in active {
            guard !Task.isCancelled, identity == identityGeneration, generation == runPollingGeneration,
                  selectedConversationID == conversationID, isApplicationActive else { return }
            do {
                let run = try await api.run(session, runID: record.runID)
                guard !Task.isCancelled, identity == identityGeneration, generation == runPollingGeneration,
                      selectedConversationID == conversationID, isApplicationActive else { return }
                try recordRun(run, expected: record)
            } catch {
                guard !Task.isCancelled, identity == identityGeneration, generation == runPollingGeneration,
                      selectedConversationID == conversationID, isApplicationActive else { return }
                if let index = runRecords.firstIndex(where: { $0.id == record.id && !$0.status.isTerminal }) {
                    runRecords[index].pollingError = POSCoreBridge.message(for: POSCoreBridge.apiError(from: error))
                }
                if case .unauthorized = POSCoreBridge.apiError(from: error) {
                    handle(error)
                    persistSnapshot()
                    return
                }
            }
            persistSnapshot()
        }
    }

    public func cancelRun(_ runID: String) async {
        guard phase.isReady, hasValidatedServer, isApplicationActive, let api, let session,
              let record = runRecords.first(where: { $0.id == runID && $0.conversationID == selectedConversationID }),
              !record.status.isTerminal, !cancelingRunIDs.contains(runID) else { return }
        let identity = identityGeneration
        cancelingRunIDs.insert(runID)
        defer { if identity == identityGeneration { cancelingRunIDs.remove(runID) } }
        do {
            let run = try await api.cancelRun(session, runID: runID)
            guard identity == identityGeneration else { return }
            guard RunStatus(rawValue: run.status)?.isTerminal == true else {
                throw POSAPIError.decoding("取消响应尚未进入终态")
            }
            try recordRun(run, expected: record)
        } catch {
            guard identity == identityGeneration else { return }
            if let index = runRecords.firstIndex(where: { $0.id == runID && !$0.status.isTerminal }) {
                runRecords[index].cancellationError = "取消结果未确认：" + POSCoreBridge.message(for: POSCoreBridge.apiError(from: error))
            }
            if case .unauthorized = POSCoreBridge.apiError(from: error) { handle(error) }
        }
        persistSnapshot()
        startRunPolling()
    }

    private func recordRun(_ run: Run, expected: RunRecord? = nil) throws {
        guard let status = RunStatus(rawValue: run.status),
              expected == nil || (run.id == expected?.runID && run.conversationId == expected?.conversationID && run.messageId == expected?.messageID) else {
            throw POSAPIError.decoding("运行响应与会话或状态不匹配")
        }
        if let index = runRecords.firstIndex(where: { $0.id == run.id }) {
            guard runRecords[index].conversationID == run.conversationId, runRecords[index].messageID == run.messageId else {
                throw POSAPIError.decoding("运行响应与已保存的消息不匹配")
            }
            guard runRecords[index].goalID == nil || runRecords[index].goalID == run.goalId else {
                throw POSAPIError.decoding("运行的目标关联与原回执不匹配")
            }
            // 取消与轮询可并发，终态不能被迟到的 running/queued 响应覆盖。
            if let goalID = run.goalId { runRecords[index].goalID = goalID }
            guard !runRecords[index].status.isTerminal else { return }
            runRecords[index].status = status
            runRecords[index].serverError = run.error
            runRecords[index].pollingError = nil
            if status.isTerminal { runRecords[index].cancellationError = nil }
        } else {
            runRecords.append(RunRecord(runID: run.id, conversationID: run.conversationId,
                messageID: run.messageId, status: status, serverError: run.error, goalID: run.goalId))
        }
    }

    private func startRunPolling() {
        stopRunPolling()
        guard phase.isReady, hasValidatedServer, isApplicationActive, let id = selectedConversationID,
              currentRunRecords.contains(where: { !$0.status.isTerminal }) else { return }
        let generation = runPollingGeneration
        runPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runPollingGeneration == generation,
                      self.selectedConversationID == id, self.isApplicationActive else { return }
                await self.refreshRunStates()
                guard self.currentRunRecords.contains(where: { !$0.status.isTerminal }) else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    private func stopRunPolling() {
        runPollingGeneration += 1
        runPollingTask?.cancel()
        runPollingTask = nil
    }

    // MARK: - v2 目标、持久命令草稿与固定问答依据

    public func refreshGoals() async {
        guard phase.isReady, hasValidatedServer, !isLoadingGoals, let api, let session else { return }
        let identity = identityGeneration
        isLoadingGoals = true
        goalsError = nil
        defer { if identity == identityGeneration { isLoadingGoals = false } }
        do {
            let capabilities = try await api.capabilities(session)
            guard identity == identityGeneration else { return }
            goalsCapabilities = capabilities
            guard capabilities.supportsGoals else {
                goalsOnline = false
                goalsError = "当前服务器尚未提供目标能力；已有缓存仍可查看。"
                return
            }
            async let active = api.goals(session, status: .active)
            async let completed = api.goals(session, status: .completed)
            async let archived = api.goals(session, status: .archived)
            let lists = try await (active, completed, archived)
            guard identity == identityGeneration else { return }
            for goal in lists.0 + lists.1 + lists.2 { mergeGoal(goal) }
            goalsOnline = true
            goalsLastSyncedAt = POSDate.isoString(Date())
            persistSnapshot()
        } catch {
            guard identity == identityGeneration else { return }
            if case .server(404, _, _) = POSCoreBridge.apiError(from: error) { goalsCapabilities = POSCapabilities() }
            handleGoalError(error)
        }
    }

    public func loadGoal(_ id: String, force: Bool = false) async {
        let identity = identityGeneration
        if goalsCapabilities == nil { await refreshGoals() }
        guard identity == identityGeneration, phase.isReady, hasValidatedServer,
              goalsCapabilities?.supportsGoals == true, (force || !loadingGoalIDs.contains(id)), let api, let session else { return }
        let requestGeneration = (goalDetailGenerations[id] ?? 0) + 1
        goalDetailGenerations[id] = requestGeneration
        loadingGoalIDs.insert(id)
        defer {
            if identity == identityGeneration, goalDetailGenerations[id] == requestGeneration { loadingGoalIDs.remove(id) }
        }
        do {
            let detail = try await api.goal(session, goalID: id)
            guard identity == identityGeneration, goalDetailGenerations[id] == requestGeneration else { return }
            if let cached = goalDetails[id], cached.viewRevision > detail.viewRevision { return }
            goalDetails[id] = detail
            mergeGoal(detail.goal)
            goalsOnline = true
            persistSnapshot()
        } catch {
            guard identity == identityGeneration, goalDetailGenerations[id] == requestGeneration else { return }
            handleGoalError(error)
        }
    }

    public func loadGoalTask(_ id: String, force: Bool = false) async {
        guard phase.isReady, hasValidatedServer, goalsCapabilities?.supportsGoals == true,
              (force || !loadingGoalTaskIDs.contains(id)), let api, let session else { return }
        let identity = identityGeneration
        let requestGeneration = (goalTaskGenerations[id] ?? 0) + 1
        goalTaskGenerations[id] = requestGeneration
        loadingGoalTaskIDs.insert(id)
        defer {
            if identity == identityGeneration, goalTaskGenerations[id] == requestGeneration { loadingGoalTaskIDs.remove(id) }
        }
        do {
            let detail = try await api.goalTask(session, taskID: id)
            guard identity == identityGeneration, goalTaskGenerations[id] == requestGeneration else { return }
            if let cached = goalTaskDetails[id], cached.task.revision > detail.task.revision { return }
            goalTaskDetails[id] = detail
            goalsOnline = true
            persistSnapshot()
        } catch {
            guard identity == identityGeneration, goalTaskGenerations[id] == requestGeneration else { return }
            handleGoalError(error)
        }
    }

    /// 一个表单入口只有一个草稿槽；关闭、离线和重启均保留，不会悄悄替换在途命令。
    @discardableResult
    public func beginGoalDraft(_ proposal: GoalDraft) -> String {
        guard phase.isReady else { return proposal.id }
        if goalDrafts[proposal.id] == nil {
            goalDrafts[proposal.id] = proposal
            persistSnapshot()
        }
        return proposal.id
    }

    public func updateGoalDraft(_ draft: GoalDraft, identity: String) {
        guard identity == cacheIdentityKey, phase.isReady, let saved = goalDrafts[draft.id],
              !saved.isLocked, !isGoalDraftSaving(draft.id), saved.kind == draft.kind,
              saved.goalID == draft.goalID, saved.taskID == draft.taskID else { return }
        goalDrafts[draft.id] = draft
        persistSnapshot()
    }

    /// 本机重试只写原子快照，不产生云端请求；成功后当前所有草稿才算已保留。
    @discardableResult
    public func persistGoalDraftsLocally(identity: String) -> Bool {
        guard identity == cacheIdentityKey, phase.isReady else { return false }
        return persistSnapshot()
    }

    public func isGoalDraftSaving(_ id: String) -> Bool {
        guard let draft = goalDrafts[id] else { return false }
        return pendingGoalActions.contains(draft.goalID ?? draft.id)
    }

    public func discardGoalDraft(_ id: String, identity: String) {
        guard identity == cacheIdentityKey, let draft = goalDrafts[id],
              !draft.hasUncertainResult, !isGoalDraftSaving(id) else { return }
        goalDrafts[id] = nil
        persistSnapshot()
    }

    /// 仅在服务器明确拒绝后，经用户点击才用新版本生成新命令；保留表单输入。
    public func reviseGoalDraft(_ id: String, identity: String) async {
        guard identity == cacheIdentityKey, let saved = goalDrafts[id],
              saved.state == .conflict || saved.state == .rejected else { return }
        let generation = identityGeneration
        if let goalID = saved.goalID {
            await loadGoal(goalID, force: true)
            guard generation == identityGeneration else { return }
        }
        if let taskID = saved.taskID {
            await loadGoalTask(taskID, force: true)
            guard generation == identityGeneration else { return }
        }
        guard generation == identityGeneration, canEditGoals, var draft = goalDrafts[id], draft == saved else { return }
        if let taskID = draft.taskID {
            guard let latest = goalTaskDetails[taskID]?.task else { return }
            draft.expectedRevision = latest.revision
        } else if let goalID = draft.goalID {
            guard let latest = goals.first(where: { $0.id == goalID }) ?? goalDetails[goalID]?.goal else { return }
            draft.expectedRevision = latest.revision
        }
        draft.mutation = nil
        draft.state = .editing
        draft.error = nil
        goalDrafts[id] = draft
        persistSnapshot()
    }

    @discardableResult
    public func submitGoalDraft(_ id: String, identity: String) async -> Bool {
        guard identity == cacheIdentityKey, var draft = goalDrafts[id], !isGoalDraftSaving(id),
              canEditGoals, draft.state != .conflict, draft.state != .rejected, let api, let session else { return false }
        // 不允许同一目标存在第二个未确定结果的命令。
        guard !goalDrafts.values.contains(where: { $0.id != id && $0.goalID == draft.goalID && $0.hasUncertainResult }) else {
            goalsError = "请先恢复此目标中保存结果待确认的草稿"
            return false
        }
        guard let mutation = draft.mutation ?? draft.makeMutation() else { return false }
        draft.mutation = mutation
        draft.state = .sending
        draft.error = nil
        goalDrafts[id] = draft
        guard persistSnapshot() else {
            draft.state = .unconfirmed
            draft.error = "本机未能保存原操作，尚未发送；请检查存储空间后恢复保存"
            goalDrafts[id] = draft
            return false
        }
        let generation = identityGeneration
        let busyKey = draft.goalID ?? draft.id
        pendingGoalActions.insert(busyKey)
        defer { if generation == identityGeneration { pendingGoalActions.remove(busyKey) } }
        do {
            var refreshedGoalID = draft.goalID
            switch mutation {
            case .createGoal(let request):
                let goal = try await api.createGoal(session, request)
                guard generation == identityGeneration else { return false }
                mergeGoal(goal)
                refreshedGoalID = goal.id
            case .goal(let goalID, let command):
                let goal = try await api.updateGoal(session, goalID: goalID, command)
                guard generation == identityGeneration else { return false }
                mergeGoal(goal)
            case .createTask(let goalID, let request):
                let task = try await api.createGoalTask(session, goalID: goalID, request)
                guard generation == identityGeneration else { return false }
                guard task.goalId == goalID else { throw POSAPIError.decoding("任务响应与目标不匹配") }
            case .task(let taskID, let goalID, let command):
                let task = try await api.updateGoalTask(session, taskID: taskID, command)
                guard generation == identityGeneration else { return false }
                guard task.goalId == goalID else { throw POSAPIError.decoding("任务响应与目标不匹配") }
            }
            guard generation == identityGeneration else { return false }
            goalDrafts[id] = nil
            goalsError = nil
            persistSnapshot()
            if let goalID = refreshedGoalID {
                await loadGoal(goalID, force: true)
                guard generation == identityGeneration else { return false }
            }
            if let taskID = draft.taskID {
                await loadGoalTask(taskID, force: true)
                guard generation == identityGeneration else { return false }
            }
            await refreshGoals()
            guard generation == identityGeneration else { return false }
            return true
        } catch {
            guard generation == identityGeneration else { return false }
            let failure = POSCoreBridge.apiError(from: error)
            switch failure {
            case .conflict:
                draft.state = .conflict
                draft.error = "内容已更新；本地输入已保留。请核对服务器最新内容，再明确选择继续编辑。"
            case .unauthorized:
                draft.state = .rejected
                draft.error = "登录已失效；草稿已保留，重新配对后再处理。"
            case .server(let status, _, _) where (400..<500).contains(status) && status != 408 && status != 429:
                draft.state = .rejected
                draft.error = POSCoreBridge.message(for: failure)
            default:
                draft.state = .unconfirmed
                draft.error = "保存结果未确认；已保留原操作与输入，请恢复保存以查询或重试同一次操作。"
            }
            goalDrafts[id] = draft
            persistSnapshot()
            handleGoalError(error)
            if draft.state == .conflict {
                let message = goalsError
                if let goalID = draft.goalID {
                    await loadGoal(goalID, force: true)
                    guard generation == identityGeneration else { return false }
                }
                if let taskID = draft.taskID {
                    await loadGoalTask(taskID, force: true)
                    guard generation == identityGeneration else { return false }
                }
                goalsError = message
            }
            return false
        }
    }

    public func associateCurrentConversation(with goalID: String?) {
        guard let id = selectedConversationID else { return }
        if let goalID {
            guard supportsGoalQuestions, goals.contains(where: { $0.id == goalID }) || goalDetails[goalID] != nil else { return }
        }
        conversationGoalIDs[id] = goalID
        persistSnapshot()
    }

    public func chatAboutGoal(_ goalID: String) async {
        guard supportsGoalQuestions else { return }
        let identity = identityGeneration
        if selectedConversationID == nil { await createConversation() }
        guard identity == identityGeneration, selectedConversationID != nil else { return }
        associateCurrentConversation(with: goalID)
        selectedTab = 0
    }

    public func loadGoalContext(_ runID: String) async {
        guard goalContexts[runID] == nil, !loadingGoalContextIDs.contains(runID), phase.isReady,
              hasValidatedServer, let record = runRecords.first(where: { $0.id == runID }),
              let goalID = record.goalID, let api, let session else { return }
        let identity = identityGeneration
        loadingGoalContextIDs.insert(runID)
        goalContextErrors[runID] = nil
        defer { if identity == identityGeneration { loadingGoalContextIDs.remove(runID) } }
        do {
            guard let context = try await api.goalContext(session, runID: runID) else {
                throw POSAPIError.decoding("本次回答没有可读取的目标资料快照")
            }
            guard identity == identityGeneration else { return }
            guard context.runId == runID, context.goalId == goalID else { throw POSAPIError.decoding("回答依据与原目标不匹配") }
            goalContexts[runID] = context
            persistSnapshot()
        } catch {
            guard identity == identityGeneration else { return }
            goalContextErrors[runID] = "本次依据尚未读到：" + POSCoreBridge.message(for: POSCoreBridge.apiError(from: error))
            if case .unauthorized = POSCoreBridge.apiError(from: error) { handle(error) }
        }
    }

    public func setGoalsTabActive(_ active: Bool) {
        goalsTabActive = active
        startGoalsPolling()
    }
    public func setVisibleGoal(_ id: String?) { visibleGoalID = id; startGoalsPolling() }
    public func setVisibleGoalTask(_ id: String?) { visibleGoalTaskID = id; startGoalsPolling() }
    public func dismissGoalsError() { goalsError = nil }

    private func refreshVisibleGoals() async {
        guard isApplicationActive, !Task.isCancelled,
              goalsTabActive || visibleGoalID != nil || visibleGoalTaskID != nil else { return }
        let generation = identityGeneration
        await refreshGoals()
        guard generation == identityGeneration, isApplicationActive, !Task.isCancelled else { return }
        if let id = visibleGoalID { await loadGoal(id) }
        guard generation == identityGeneration, isApplicationActive, !Task.isCancelled else { return }
        if let id = visibleGoalTaskID { await loadGoalTask(id) }
    }

    private func startGoalsPolling() {
        stopGoalsPolling()
        guard phase.isReady, hasValidatedServer, isApplicationActive,
              goalsTabActive || visibleGoalID != nil || visibleGoalTaskID != nil else { return }
        let generation = goalsPollingGeneration
        goalsPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard let self, generation == self.goalsPollingGeneration, self.isApplicationActive else { return }
                await self.refreshVisibleGoals()
            }
        }
    }

    private func stopGoalsPolling() {
        goalsPollingGeneration += 1
        goalsPollingTask?.cancel()
        goalsPollingTask = nil
    }

    private func mergeGoal(_ goal: Goal) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            let saved = goals[index]
            guard saved.revision <= goal.revision else { return }
            if saved.revision == goal.revision, (saved.viewRevision ?? 0) > (goal.viewRevision ?? 0) { return }
            goals[index] = goal
        } else { goals.append(goal) }
        goals.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    private func handleGoalError(_ error: Error) {
        let failure = POSCoreBridge.apiError(from: error)
        switch failure {
        case .unauthorized:
            goalsOnline = false
            handle(failure)
            goalsError = POSCoreBridge.message(for: failure)
        case .transport:
            goalsOnline = false
            goalsError = "离线 · 已保留缓存与草稿，连接恢复后再次保存。"
        case .server(404, _, _), .server(501, _, _):
            goalsOnline = false
            goalsError = "目标接口暂不可用；已有缓存仍可查看，请刷新重试。"
        case .conflict:
            goalsError = "内容已更新；已保留本地草稿，请核对服务器最新内容。"
        default:
            goalsOnline = false
            goalsError = POSCoreBridge.message(for: failure)
        }
    }

    private func resetGoalRequests() {
        stopGoalsPolling()
        goalsCapabilities = nil
        goalsError = nil
        goalsOnline = false
        isLoadingGoals = false
        loadingGoalIDs = []
        loadingGoalTaskIDs = []
        loadingGoalContextIDs = []
        goalContextErrors = [:]
        isCreatingGoal = false
        pendingGoalActions = []
        goalDetailGenerations = [:]
        goalTaskGenerations = [:]
    }

    // 旧功能没有 v2 路由，调用时也只报告未接入，绝不伪造成功。
    public func approve(taskID: String) async { notice = "任务审批未接入 v2" }
    public func reject(taskID: String, note: String?) async { notice = "任务审批未接入 v2" }
    public func accept(taskID: String) async { notice = "任务验收未接入 v2" }
    public func requestRework(taskID: String, note: String?) async { notice = "任务验收未接入 v2" }
    public func dismissNotice() { notice = nil }

    private func handle(_ error: Error) {
        let failure = POSCoreBridge.apiError(from: error)
        hasCurrentModel = false
        connection = .offline(POSCoreBridge.message(for: failure))
        notice = POSCoreBridge.message(for: failure)
        switch failure {
        case .unauthorized:
            hasValidatedServer = false
            stopSync()
            stopRunPolling()
            stopGoalsPolling()
            phase = .failed("登录已失效，请重新配对")
        case .server(_, "v2_unavailable", let detail):
            hasValidatedServer = false
            stopSync()
            stopRunPolling()
            stopGoalsPolling()
            phase = .failed(detail)
        case .conflict:
            needsRefresh = true
        default: break
        }
    }

    private func startSync() {
        stopSync()
        guard phase.isReady, hasValidatedServer, isApplicationActive, let api, let session, let id = selectedConversationID else { return }
        let generation = syncGeneration
        let engine = SyncEngine(api: api, session: session, conversationID: id, store: snapshotStore(), waitSeconds: 20)
        syncEngine = engine
        syncTask = Task { [weak self] in
            let stream = await engine.start()
            for await event in stream {
                guard let self, !Task.isCancelled, self.syncGeneration == generation,
                      self.selectedConversationID == id else { break }
                switch event {
                case .connected: self.connection = .online
                case .disconnected(let error): self.handle(error)
                case .messages(let incoming):
                    self.apply(incoming, to: id)
                    self.lastSyncedAt = Date()
                    self.persistSnapshot()
                case .cursor(let cursor):
                    self.updateCursor(cursor, conversationID: id)
                    self.persistSnapshot()
                @unknown default:
                    break
                }
            }
            await engine.stop()
        }
    }

    private func stopSync() {
        syncGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        if let engine = syncEngine { Task { await engine.stop() } }
        syncEngine = nil
    }

    private func apply(_ incoming: [ChatMessage], to id: String) {
        let confirmedRequestIDs = Set(incoming.compactMap { message -> String? in
            guard message.conversationID == id, message.role == "user" else { return nil }
            guard runRecords.contains(where: { $0.conversationID == id && $0.messageID == message.id }) else { return nil }
            return message.clientRequestID
        })
        pendingMessages.removeAll {
            $0.conversationID == id && confirmedRequestIDs.contains($0.clientRequestID)
        }
        let old = id == selectedConversationID ? messages : conversationStates[id]?.messages ?? []
        var byID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for message in incoming where message.conversationID == id { byID[message.id] = message }
        let merged = byID.values.sorted(by: POSCoreBridge.messageOrder)
        let savedCursor = id == selectedConversationID ? cursor : conversationStates[id]?.cursor ?? 0
        conversationStates[id] = ConversationSnapshot(conversationID: id, messages: merged, cursor: savedCursor)
        if id == selectedConversationID { messages = merged }
    }

    private func updateCursor(_ value: Int, conversationID id: String) {
        let state = conversationStates[id]
        let oldCursor = id == selectedConversationID ? cursor : state?.cursor ?? 0
        let updated = max(oldCursor, value)
        conversationStates[id] = ConversationSnapshot(conversationID: id,
            messages: id == selectedConversationID ? messages : state?.messages ?? [], cursor: updated)
        if id == selectedConversationID { cursor = updated }
    }

    private func saveCurrentConversation() {
        guard let id = selectedConversationID else { return }
        conversationStates[id] = ConversationSnapshot(conversationID: id, messages: messages, cursor: cursor)
    }

    private func snapshotStore() -> any SnapshotStore {
        if let store { return store }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let identity = cacheIdentityKey
        let directory = base.appendingPathComponent("com.personalos.ios", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(POSCoreBridge.stableDigest(identity), isDirectory: true)
        let created = FileSnapshotStore(directory: directory)
        store = created
        return created
    }

    private func hydrateFromSnapshot() {
        guard let snapshot = try? snapshotStore().loadSnapshot() else { return }
        guard snapshot.identityKey == nil || snapshot.identityKey == cacheIdentityKey else { return }
        restoredSnapshot = snapshot
        conversations = snapshot.conversations
        selectedConversationID = snapshot.selectedConversationID
        pendingMessages = snapshot.pendingMessages
        runRecords = snapshot.runRecords
        goals = snapshot.goals
        goalDetails = Dictionary(snapshot.goalDetails.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        conversationGoalIDs = snapshot.conversationGoalIDs
        goalsLastSyncedAt = snapshot.goalCache.lastSyncedAt
        goalTaskDetails = Dictionary(snapshot.goalCache.taskDetails.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        goalContexts = Dictionary(snapshot.goalCache.contexts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        goalDrafts = Dictionary(snapshot.goalCache.drafts.map { saved in
            var draft = saved
            if draft.state == .sending { draft.state = .unconfirmed }
            return (draft.id, draft)
        }, uniquingKeysWith: { _, newer in newer })
        conversationStates = Dictionary(snapshot.conversationStates.map { ($0.conversationID, $0) },
                                        uniquingKeysWith: { _, newer in newer })
        if let id = selectedConversationID {
            messages = conversationStates[id]?.messages ?? []
            cursor = max(0, conversationStates[id]?.cursor ?? 0)
        }
        lastSyncedAt = POSDate.parse(snapshot.savedAt)
    }

    @discardableResult
    private func persistSnapshot() -> Bool {
        saveCurrentConversation()
        let snapshot = CachedSnapshot(savedAt: POSDate.isoString(Date()),
            timeline: restoredSnapshot?.timeline ?? [], cursor: restoredSnapshot?.cursor ?? 0,
            tasks: restoredSnapshot?.tasks ?? [], context: restoredSnapshot?.context,
            conversations: conversations, selectedConversationID: selectedConversationID,
            conversationStates: conversationStates.values.sorted { $0.conversationID < $1.conversationID },
            pendingMessages: pendingMessages, runRecords: runRecords,
            goals: goals, goalDetails: goalDetails.values.sorted { $0.id < $1.id },
            conversationGoalIDs: conversationGoalIDs, identityKey: cacheIdentityKey,
            goalCache: GoalCache(lastSyncedAt: goalsLastSyncedAt,
                taskDetails: goalTaskDetails.values.sorted { $0.id < $1.id },
                drafts: goalDrafts.values.sorted { $0.id < $1.id },
                contexts: goalContexts.values.sorted { $0.id < $1.id }))
        do {
            try snapshotStore().saveSnapshot(snapshot)
            goalDraftStorageError = nil
            return true
        } catch {
            notice = "本地快照保存失败，请检查存储空间后重试"
            goalDraftStorageError = "最新更改尚未保存到本机，重启应用后可能丢失。请检查存储空间并重试本机保存。"
            return false
        }
    }
}
