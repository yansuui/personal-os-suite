import Foundation
import Combine
import POSCore

/// 界面层状态所有者。
///
/// 公开面严格对齐 CONTRACT §4：状态机 `.signedOut` → `.pairing` → `.ready` / `.failed(String)`，
/// 网络与同步一律走 POSCore 的 `POSAPI` / `SyncEngine` / `CredentialStore` / `SnapshotStore`，
/// 不自己 new 网络栈。
@MainActor
public final class AppModel: ObservableObject {

    // MARK: - 契约公开状态（CONTRACT §4）

    @Published public private(set) var phase: AppPhase = .signedOut
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var tasks: [TaskSummary] = []
    @Published public private(set) var context: ContextSnapshot?
    @Published public private(set) var presence: Presence?
    @Published public private(set) var lastSyncedAt: Date?

    // MARK: - 契约外扩展状态（只增不改，供各页面消费）

    /// 在线/离线横幅。
    @Published public private(set) var connection: ConnectionState = .unknown
    /// 当前服务器地址（配对成功后会更新为传入值）。
    @Published public private(set) var serverURL: URL
    /// 当前会话，nil 表示未配对。
    @Published public private(set) var session: AuthSession?
    /// 正在并行刷新。
    @Published public private(set) var isRefreshing: Bool = false
    /// 正在发送消息。
    @Published public private(set) var isSending: Bool = false
    /// 正在提交服务端操作的任务 id，用于按钮进行中态。
    @Published public private(set) var pendingTaskActions: Set<String> = []
    /// 服务端返回 409 后置真：调用方必须刷新而不是覆盖本地。
    @Published public private(set) var needsRefresh: Bool = false
    /// 一次性提示（错误/通知），由页面展示并可关闭。
    @Published public private(set) var notice: String?
    /// 助手输入框草稿；发送失败会回填，避免用户丢字。
    @Published public var draft: String = ""

    // MARK: - 依赖

    private var api: (any POSAPI)?
    /// 按服务器地址重建网络实现；配对页填了新地址时必须用它，否则地址栏形同虚设。
    private let apiFactory: ((URL) -> (any POSAPI))?
    private let credentials: any CredentialStore
    private let injectedStore: (any SnapshotStore)?
    private var store: (any SnapshotStore)?

    private var cursor: Int = 0
    private var syncEngine: SyncEngine?
    private var syncTask: Task<Void, Never>?
    /// 防止根视图重建时重复走「读 Keychain → 恢复会话」流程（避免 401 后反复回到配对页）。
    private var hasBootstrapped = false

    /// 长轮询秒数；SyncEngine 内部按 waitSeconds + 10 计算超时。
    private static let longPollSeconds = 20
    /// 上次配对成功的服务器地址；重启后仍要连它，而不是回到 Info.plist 的默认值。
    private static let serverURLDefaultsKey = "pos.serverURL"

    // 网络实现的装配点固定在 App 层（POSApp 注入 `apiFactory`），界面层不引用 POSCore 的
    // 具体实现类型。工厂比实例多一个能力：配对页改了服务器地址时按新地址重建客户端。
    // 没有工厂也没有实例时优雅降级：仍可读离线快照，配对/发送给出明确提示。
    public init(serverURL: URL,
                api: POSAPI? = nil,
                apiFactory: ((URL) -> (any POSAPI))? = nil,
                credentials: CredentialStore = KeychainCredentialStore(),
                store: SnapshotStore? = nil) {
        self.serverURL = serverURL
        self.api = api
        self.apiFactory = apiFactory
        self.credentials = credentials
        self.injectedStore = store
        self.store = store
    }

    // MARK: - 派生信息

    /// 当前设备名（来自会话）。
    public var deviceName: String {
        session?.device.name ?? ""
    }

    /// 待我决策（审批 + 验收）的条数，用于 Tab 角标。
    public var pendingDecisionCount: Int {
        tasks.reduce(into: 0) { count, task in
            if task.isAwaitingApproval || task.isAwaitingVerdict {
                count += 1
            }
        }
    }

    // MARK: - 启动

    /// 读 Keychain 恢复会话；有会话则先读离线快照（离线可看）→ `.ready` → 启动同步 → 刷新。
    /// 无会话则 `.signedOut`。
    public func bootstrap() async {
        // 只恢复一次：配对成功/失败后根视图会重建，重复恢复会造成 401 → 配对页 → 再恢复的循环。
        if hasBootstrapped {
            if phase.isReady {
                await refresh()
            }
            return
        }
        hasBootstrapped = true

        switch phase {
        case .ready:
            await refresh()
            return
        case .pairing:
            return
        case .signedOut, .failed:
            break
        }

        let restored: AuthSession?
        do {
            restored = try credentials.load()
        } catch {
            restored = nil
            notice = "读取本机配对凭据失败，请重新配对"
        }

        guard let restored else {
            phase = .signedOut
            connection = .unknown
            return
        }

        session = restored
        // 恢复上次配对用的服务器地址；否则换过服务器的手机会连回 Info.plist 的默认地址。
        if let saved = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey),
           let savedURL = URL(string: saved),
           savedURL.scheme == "http" || savedURL.scheme == "https" {
            serverURL = savedURL
        }
        if api == nil, let factory = apiFactory {
            api = factory(serverURL)
        }
        hydrateFromSnapshot()
        phase = .ready
        startSync()
        await refresh()
    }

    // MARK: - 配对

    public func pair(serverURL: URL, secret: String, deviceName: String) async {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "iPhone" : trimmedName

        // 网络实现按「本次填写的地址」装配：注入的实例优先，其次用工厂重建。
        // 没有这一步，配对页的地址栏不会影响任何请求（真机永远连默认地址）。
        let pairedAPI: any POSAPI
        if let injected = api {
            pairedAPI = injected
        } else if let factory = apiFactory {
            pairedAPI = factory(serverURL)
        } else {
            phase = .failed("缺少网络实现：AppModel 未注入 POSAPI 实现")
            return
        }
        guard !trimmedSecret.isEmpty else {
            phase = .failed("请输入配对密钥")
            return
        }
        guard serverURL.scheme == "http" || serverURL.scheme == "https", serverURL.host != nil else {
            phase = .failed("服务器地址无效，需要形如 http://192.168.1.10:3080")
            return
        }

        phase = .pairing
        connection = .unknown
        notice = nil

        do {
            let request = POSCoreBridge.pairRequest(name: name, role: "client")
            let newSession = try await pairedAPI.pair(secret: trimmedSecret, request)
            api = pairedAPI
            adopt(session: newSession, serverURL: serverURL)
            await refresh()
        } catch {
            let message = POSCoreBridge.pairFailureMessage(error: error)
            if session != nil {
                // 已配对过的手机在「重新配对」里输错密钥：保留现有会话，退回主界面。
                phase = .ready
                notice = message
            } else {
                phase = .failed(message)
                connection = .unknown
            }
        }
    }

    /// 配对成功后的接线：写 Keychain、建 FileSnapshotStore、启动 SyncEngine、进入 `.ready`。
    private func adopt(session newSession: AuthSession, serverURL newURL: URL) {
        self.serverURL = newURL
        self.session = newSession
        cursor = 0
        messages = []
        tasks = []
        context = nil
        presence = nil
        lastSyncedAt = nil
        needsRefresh = false
        connection = .unknown
        pendingTaskActions = []

        if injectedStore == nil {
            // POSCore 的 FileSnapshotStore 只接收目录（见 SnapshotStore.swift 的 CONTRACT-DEV），
            // 因此由界面层按「服务器 + 设备 id」派生目录，避免不同账号离线缓存互相覆盖。
            store = FileSnapshotStore(
                directory: snapshotDirectory(serverURL: newURL, deviceID: newSession.device.id)
            )
        }
        do {
            try credentials.save(newSession)
        } catch {
            notice = "配对成功，但凭据未能写入 Keychain：下次启动需要重新配对"
        }
        UserDefaults.standard.set(newURL.absoluteString, forKey: Self.serverURLDefaultsKey)

        phase = .ready
        startSync()
    }

    // MARK: - 登出

    public func signOut() {
        stopSync()

        var clearFailure: String?
        do {
            try credentials.clear()
        } catch {
            clearFailure = "本机凭据清除失败"
        }

        if injectedStore == nil {
            store = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.serverURLDefaultsKey)
        if apiFactory != nil {
            api = nil
        }

        session = nil
        messages = []
        tasks = []
        context = nil
        presence = nil
        lastSyncedAt = nil
        cursor = 0
        needsRefresh = false
        pendingTaskActions = []
        isRefreshing = false
        isSending = false
        connection = .unknown
        draft = ""
        notice = clearFailure
        phase = .signedOut
    }

    // MARK: - 刷新

    /// 并行拉 tasks / context / presence。任一失败都降级为「保留旧数据 + 更新横幅与最后同步时间」。
    public func refresh() async {
        guard case .ready = phase else { return }
        guard let api = self.api, let session = self.session else { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        async let taskOutcome: Result<TaskList, POSAPIError> = POSCoreBridge.attempt { try await api.tasks(session) }
        async let contextOutcome: Result<ContextSnapshot, POSAPIError> = POSCoreBridge.attempt { try await api.context(session) }
        async let presenceOutcome: Result<Presence, POSAPIError> = POSCoreBridge.attempt { try await api.presence(session) }

        let (taskResult, contextResult, presenceResult) = await (taskOutcome, contextOutcome, presenceOutcome)

        var failure: POSAPIError?
        switch taskResult {
        case .success(let list):
            tasks = list.tasks
        case .failure(let error):
            failure = error
        }
        switch contextResult {
        case .success(let snapshot):
            context = snapshot
        case .failure(let error):
            if failure == nil { failure = error }
        }
        switch presenceResult {
        case .success(let value):
            presence = value
        case .failure(let error):
            if failure == nil { failure = error }
        }

        guard let failure else {
            connection = .online
            lastSyncedAt = Date()
            needsRefresh = false
            notice = nil
            persistSnapshot()
            return
        }

        if case .unauthorized = failure {
            expireSession()
            return
        }

        connection = .offline(POSCoreBridge.message(for: failure))
        if case .conflict = failure {
            needsRefresh = true
            notice = "服务端数据已更新，请下拉刷新后重试"
        } else if tasks.isEmpty && context == nil {
            notice = "同步失败：\(POSCoreBridge.message(for: failure))"
        }
    }

    /// 断线重试入口：重建同步流并刷新一次。
    public func reconnect() async {
        guard case .ready = phase else { return }
        connection = .unknown
        startSync()
        await refresh()
    }

    // MARK: - 发消息

    /// 先把用户消息本地插入列表，再用同一个 `clientRequestID` 做一次重试。
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard case .ready = phase else {
            notice = "连接尚未就绪，稍后再试"
            return
        }
        guard let api = self.api, let session = self.session else {
            notice = "缺少网络实现，无法发送消息（CONTRACT-GAP）"
            return
        }
        guard !isSending else { return }

        let clientRequestID = UUID().uuidString
        let placeholderID = "local-\(clientRequestID)"
        let placeholder = POSCoreBridge.outgoingMessage(
            id: placeholderID,
            seq: nextLocalSequence(),
            text: trimmed
        )
        mergeTimeline([placeholder])
        isSending = true
        defer { isSending = false }

        var lastFailure: POSAPIError?
        var didConflict = false
        for attempt in 0..<2 {
            do {
                let request = POSCoreBridge.sendRequest(clientRequestID: clientRequestID, text: trimmed)
                let ack = try await api.sendMessage(session, request)
                connection = .online
                renameMessage(id: placeholderID, to: ack.messageID)
                persistSnapshot()
                return
            } catch {
                let failure = POSCoreBridge.apiError(from: error)
                lastFailure = failure
                if case .unauthorized = failure {
                    break
                }
                if case .conflict = failure {
                    // 幂等/版本冲突：交给刷新判定，不覆盖本地
                    needsRefresh = true
                    didConflict = true
                    break
                }
                if attempt == 0 {
                    // 复用同一个 clientRequestID 重试一次
                    continue
                }
            }
        }

        // 两次都失败：撤回占位消息、回填草稿，避免重复记录或丢字
        messages.removeAll { $0.id == placeholderID }
        if draft.isEmpty {
            draft = trimmed
        }

        guard let failure = lastFailure else { return }

        if case .unauthorized = failure {
            expireSession()
            return
        }
        if didConflict {
            notice = "消息可能已发送，但服务端状态已变化，请下拉刷新确认"
            persistSnapshot()
            return
        }
        connection = .offline(POSCoreBridge.message(for: failure))
        notice = "消息未发送：\(POSCoreBridge.message(for: failure))"
        persistSnapshot()
    }

    // MARK: - 审批 / 验收

    public func approve(taskID: String) async {
        await performTaskAction(taskID: taskID) { api, session in
            try await api.approve(session, taskID: taskID, approved: true, note: nil)
        }
    }

    public func reject(taskID: String, note: String?) async {
        // v1 服务端 `POST /v1/tasks/:id/approve` 无条件批准、没有拒绝分支（server.ts:519-532），
        // 所以 POSCore 在 approved == false 时改打 `/cancel`（见 URLSessionPOSAPI 的
        // CONTRACT-DEVIATION）。这里如实告知用户：拒绝 = 取消该任务，而不是留一条「已拒绝」记录。
        await performTaskAction(taskID: taskID) { api, session in
            try await api.approve(session, taskID: taskID, approved: false, note: note)
        }
    }

    public func accept(taskID: String) async {
        await performTaskAction(taskID: taskID) { api, session in
            try await api.submitVerdict(session, taskID: taskID, verdict: "accepted", note: nil)
        }
    }

    public func requestRework(taskID: String, note: String?) async {
        await performTaskAction(taskID: taskID) { api, session in
            try await api.submitVerdict(session, taskID: taskID, verdict: "rejected", note: note)
        }
    }

    private func performTaskAction(
        taskID: String,
        _ operation: @escaping @Sendable (any POSAPI, AuthSession) async throws -> Void
    ) async {
        guard let api = self.api, let session = self.session else {
            notice = "缺少网络实现，无法提交操作（CONTRACT-GAP）"
            return
        }
        guard !pendingTaskActions.contains(taskID) else { return }

        pendingTaskActions.insert(taskID)
        defer { _ = pendingTaskActions.remove(taskID) }

        do {
            try await operation(api, session)
            connection = .online
            await refresh()
        } catch {
            let failure = POSCoreBridge.apiError(from: error)
            switch failure {
            case .conflict(let detail):
                // 409：置 needsRefresh 并提示，本地数据一律不改
                needsRefresh = true
                notice = "任务已在服务端变化（\(detail)），本地数据未改动，请下拉刷新"
            case .unauthorized:
                expireSession()
            case .transport(let detail):
                connection = .offline("网络不可达：\(detail)")
                notice = "提交失败：网络不可达，请检查连接后重试"
            case .server(let status, let code, let message):
                notice = "提交失败（\(status)\(code.isEmpty ? "" : " \(code)")）：\(message)"
            case .decoding(let detail):
                notice = "提交结果无法解析：\(detail)"
            @unknown default:
                notice = "提交失败：未知错误"
            }
        }
    }

    // MARK: - 提示

    public func dismissNotice() {
        notice = nil
    }

    // MARK: - 同步生命周期

    private func startSync() {
        guard let api = self.api, let session = self.session else { return }
        stopSync()

        let engine = SyncEngine(
            api: api,
            session: session,
            store: snapshotStore(),
            waitSeconds: Self.longPollSeconds
        )
        syncEngine = engine

        // Task 继承 @MainActor 隔离，事件在这里串行消费、不会并发改状态。
        syncTask = Task { [weak self] in
            let stream = await engine.start()
            for await event in stream {
                guard let self else {
                    await engine.stop()
                    return
                }
                if Task.isCancelled { break }
                await self.deliver(event)
            }
        }
    }

    private func stopSync() {
        syncTask?.cancel()
        syncTask = nil
        guard let engine = syncEngine else { return }
        syncEngine = nil
        Task { await engine.stop() }
    }

    /// 同步事件在主 actor 上串行消费（显式 async，避免跨隔离歧义）。
    private func deliver(_ event: SyncEvent) async {
        switch event {
        case .connected:
            connection = .online
        case .disconnected(let error):
            connection = .offline(POSCoreBridge.message(for: error))
            if case .unauthorized = error {
                expireSession()
            }
        case .messages(let incoming):
            mergeTimeline(incoming)
            lastSyncedAt = Date()
            persistSnapshot()
        case .cursor(let value):
            // 游标只增不减；负数视为无效，保留旧值
            if value >= 0 {
                cursor = value
            }
            persistSnapshot()
        @unknown default:
            break
        }
    }

    /// 会话失效：停同步并回到配对界面，但保留 Keychain，避免重复读写。
    private func expireSession() {
        stopSync()
        connection = .offline("登录已失效")
        phase = .failed("登录已失效，请重新配对")
        notice = "设备令牌已失效，请重新配对后继续"
    }

    // MARK: - 消息合并

    /// 按 id 合并去重，服务端版本覆盖本地占位版本。
    private func mergeTimeline(_ incoming: [ChatMessage]) {
        guard !incoming.isEmpty else { return }
        var byID: [String: ChatMessage] = [:]
        for message in messages {
            byID[message.id] = message
        }
        for message in incoming {
            byID[message.id] = message
        }
        messages = byID.values.sorted(by: POSCoreBridge.messageOrder)
    }

    private func nextLocalSequence() -> Int {
        let highestMessageSeq = messages.map { $0.seq }.max() ?? 0
        return max(highestMessageSeq, cursor) + 1
    }

    /// 服务端 ack 后把占位消息的 id 替换成真实 id，后续时间线按 id 去重即可。
    private func renameMessage(id: String, to newID: String) {
        guard id != newID, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let existing = messages[index]
        messages[index] = POSCoreBridge.message(
            id: newID,
            seq: existing.seq,
            role: existing.role,
            text: existing.text,
            createdAt: existing.createdAt
        )
        dedupeMessages()
    }

    private func dedupeMessages() {
        var seen = Set<String>()
        var result: [ChatMessage] = []
        result.reserveCapacity(messages.count)
        for message in messages where !seen.contains(message.id) {
            seen.insert(message.id)
            result.append(message)
        }
        messages = result.sorted(by: POSCoreBridge.messageOrder)
    }

    // MARK: - 离线快照

    private func snapshotStore() -> any SnapshotStore {
        if let store = self.store {
            return store
        }
        let created: any SnapshotStore
        if let session = self.session {
            created = FileSnapshotStore(
                directory: snapshotDirectory(serverURL: serverURL, deviceID: session.device.id)
            )
        } else {
            created = FileSnapshotStore()
        }
        store = created
        return created
    }

    /// 按「服务器 + 设备 id」派生快照子目录（服务端身份范围内隔离）。
    private func snapshotDirectory(serverURL: URL, deviceID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("com.personalos.ios", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(
                POSCoreBridge.stableDigest("\(serverURL.absoluteString)|\(deviceID)"),
                isDirectory: true
            )
    }

    /// 先读快照：断网时也能看到上次的时间线与任务。
    private func hydrateFromSnapshot() {
        let snapshot: CachedSnapshot?
        do {
            snapshot = try snapshotStore().loadSnapshot()
        } catch {
            return
        }
        guard let snapshot else { return }

        if messages.isEmpty {
            messages = snapshot.timeline.sorted(by: POSCoreBridge.messageOrder)
        }
        if tasks.isEmpty {
            tasks = snapshot.tasks
        }
        if context == nil {
            context = snapshot.context
        }
        if cursor == 0 {
            cursor = max(0, snapshot.cursor)
        }
        if lastSyncedAt == nil {
            lastSyncedAt = POSDate.parse(snapshot.savedAt)
        }
    }

    private func persistSnapshot() {
        let snapshot = POSCoreBridge.cachedSnapshot(
            savedAt: POSDate.isoString(Date()),
            timeline: messages,
            cursor: cursor,
            tasks: tasks,
            context: context
        )
        do {
            try snapshotStore().saveSnapshot(snapshot)
        } catch {
            // 快照只是离线缓存，写入失败不打断在线流程
        }
    }
}
