import Foundation
import Combine
import POSCore

/// v2 最小聊天状态；凭据与离线数据仍由 POSCore 存储。
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
    @Published public private(set) var serverURL: URL
    @Published public private(set) var session: AuthSession?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isSending = false
    @Published public private(set) var isCreatingConversation = false
    @Published public private(set) var needsRefresh = false
    @Published public private(set) var notice: String?
    @Published public var draft = ""

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
    public var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }
    public var currentPendingMessages: [PendingMessage] {
        pendingMessages.filter { $0.conversationID == selectedConversationID }
    }
    public var currentRunRecords: [RunRecord] {
        runRecords.filter { $0.conversationID == selectedConversationID }
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
        stopSync()
        stopRunPolling()
        cancelingRunIDs = []
        isRefreshing = false
        isSending = false
        isCreatingConversation = false
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
        messages = []
        conversations = []
        selectedConversationID = nil
        pendingMessages = []
        runRecords = []
        cancelingRunIDs = []
        conversationStates = [:]
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
        defer {
            if generation == identityGeneration {
                isRefreshing = false
                // 回前台时可能仍在等待这次刷新；结束后补回被后台暂停的轮询。
                if syncTask == nil { startSync() }
                if runPollingTask == nil { startRunPolling() }
            }
        }
        do {
            _ = try await api.health()
            guard generation == identityGeneration else { return }
            hasValidatedServer = true
            let device = try await api.me(session)
            guard device.role == "client" else { throw POSAPIError.unauthorized }
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
        } else {
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
        let pending = PendingMessage(conversationID: id, text: text, createdAt: POSDate.isoString(Date()))
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
        for attempt in 0..<2 {
            do {
                let ack = try await api.sendMessage(session, conversationID: pending.conversationID, pending.request)
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
            // 取消与轮询可并发，终态不能被迟到的 running/queued 响应覆盖。
            guard !runRecords[index].status.isTerminal else { return }
            runRecords[index].status = status
            runRecords[index].serverError = run.error
            runRecords[index].pollingError = nil
            if status.isTerminal { runRecords[index].cancellationError = nil }
        } else {
            runRecords.append(RunRecord(runID: run.id, conversationID: run.conversationId,
                messageID: run.messageId, status: status, serverError: run.error))
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

    // 旧功能没有 v2 路由，调用时也只报告未接入，绝不伪造成功。
    public func approve(taskID: String) async { notice = "任务审批未接入 v2" }
    public func reject(taskID: String, note: String?) async { notice = "任务审批未接入 v2" }
    public func accept(taskID: String) async { notice = "任务验收未接入 v2" }
    public func requestRework(taskID: String, note: String?) async { notice = "任务验收未接入 v2" }
    public func dismissNotice() { notice = nil }

    private func handle(_ error: Error) {
        let failure = POSCoreBridge.apiError(from: error)
        connection = .offline(POSCoreBridge.message(for: failure))
        notice = POSCoreBridge.message(for: failure)
        switch failure {
        case .unauthorized:
            hasValidatedServer = false
            stopSync()
            stopRunPolling()
            phase = .failed("登录已失效，请重新配对")
        case .server(_, "v2_unavailable", let detail):
            hasValidatedServer = false
            stopSync()
            stopRunPolling()
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
        let identity = "\(serverURL.absoluteString)|\(session?.device.id ?? "")"
        let directory = base.appendingPathComponent("com.personalos.ios", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(POSCoreBridge.stableDigest(identity), isDirectory: true)
        let created = FileSnapshotStore(directory: directory)
        store = created
        return created
    }

    private func hydrateFromSnapshot() {
        guard let snapshot = try? snapshotStore().loadSnapshot() else { return }
        restoredSnapshot = snapshot
        conversations = snapshot.conversations
        selectedConversationID = snapshot.selectedConversationID
        pendingMessages = snapshot.pendingMessages
        runRecords = snapshot.runRecords
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
            pendingMessages: pendingMessages, runRecords: runRecords)
        do { try snapshotStore().saveSnapshot(snapshot); return true }
        catch { notice = "本地快照保存失败，请检查存储空间后重试"; return false }
    }
}
