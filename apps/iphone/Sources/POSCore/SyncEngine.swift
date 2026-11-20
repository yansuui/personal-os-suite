import Foundation

/// 同步事件（CONTRACT §3 公开面）。
public enum SyncEvent: Sendable {
    /// 已连接（首次进入，以及断线后重新收到成功响应时各推一次）。
    case connected
    /// 连接失败/请求失败；随后按指数退避重连。
    case disconnected(POSAPIError)
    /// 新消息（一页）。
    case messages([ChatMessage])
    /// 游标前进。
    case cursor(Int)
}

/// 长轮询同步引擎。
///
/// 行为（CONTRACT §3 行为 4/5）：
/// - `start()` 先推 `.connected`，然后循环 `timeline(after: cursor, waitSeconds:)`；
/// - 有新消息推 `.messages`，游标前进时推 `.cursor`；空页继续等，**保持旧游标**；
/// - 出错推 `.disconnected`，按 1→2→4→…→30s 指数退避重连（封顶 30s）；
/// - `stop()` 立即取消在途请求、结束流，此后不再发起任何请求；
/// - 调用方取消消费（`for await` 提前退出）等价于 `stop()`。
public actor SyncEngine {
    private let api: POSAPI
    private let session: AuthSession
    private let store: SnapshotStore
    private let waitSeconds: Int

    /// 退避上限（秒）。
    private static let maximumBackoffSeconds = 30

    private var loopTask: Task<Void, Never>?
    private var continuation: AsyncStream<SyncEvent>.Continuation?
    /// 流的代数：防止上一轮流的 onTermination 关掉新一轮。
    private var generation = 0

    public init(api: POSAPI, session: AuthSession, store: SnapshotStore, waitSeconds: Int = 20) {
        self.api = api
        self.session = session
        self.store = store
        self.waitSeconds = waitSeconds
    }

    /// 开始同步并返回事件流。重复调用会先停掉上一轮。
    public func start() -> AsyncStream<SyncEvent> {
        stop()
        generation += 1
        let streamGeneration = generation

        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            // 消费方取消（提前退出 for-await）等价于 stop()。
            guard let engine = self else { return }
            Task {
                await engine.handleTermination(streamGeneration)
            }
        }
        loopTask = Task { [weak self] in
            guard let engine = self else { return }
            await engine.runLoop(continuation: continuation)
        }
        return stream
    }

    /// 停止同步：取消在途请求并结束流。可重复调用。
    public func stop() {
        generation += 1
        loopTask?.cancel()
        loopTask = nil
        let pending = continuation
        continuation = nil
        pending?.finish()
    }

    /// 重发本地待发消息。
    ///
    /// 本轮 pending 队列为空实现：读取一次快照确认没有待发项就返回，不发起网络请求，
    /// 也不抛错。后续版本在 `CachedSnapshot` 之外增加 pending 文件时在此实现重放，
    /// 重放必须复用原 `clientRequestID`。
    public func resendPending() async {
        _ = try? store.loadSnapshot()
    }

    // MARK: - 循环

    private func handleTermination(_ streamGeneration: Int) {
        guard generation == streamGeneration else { return }
        stop()
    }

    private func runLoop(continuation: AsyncStream<SyncEvent>.Continuation) async {
        var cursor = initialCursor()
        continuation.yield(.connected)

        var backoffSeconds = 1
        var needsReconnectNotice = false

        while !Task.isCancelled {
            do {
                let page = try await api.timeline(session, after: cursor, waitSeconds: waitSeconds)
                if Task.isCancelled { break }
                backoffSeconds = 1
                if needsReconnectNotice {
                    needsReconnectNotice = false
                    continuation.yield(.connected)
                }
                if !page.events.isEmpty {
                    continuation.yield(.messages(page.events))
                    if let advanced = advancedCursor(from: page, current: cursor) {
                        cursor = advanced
                        continuation.yield(.cursor(advanced))
                    }
                }
                // 空页：保持旧游标，继续下一轮长轮询。
            } catch {
                if Task.isCancelled { break }
                continuation.yield(.disconnected(Self.normalized(error)))
                needsReconnectNotice = true
                let delay = backoffSeconds
                backoffSeconds = min(backoffSeconds * 2, Self.maximumBackoffSeconds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                } catch {
                    // 睡眠被取消：清理后退出，不再发请求。
                    break
                }
            }
        }
        continuation.finish()
    }

    /// 初始游标取本地快照；没有快照时从 0 开始（不是错误，服务端游标本身从 1 起）。
    private func initialCursor() -> Int {
        guard let snapshot = try? store.loadSnapshot() else { return 0 }
        return max(0, snapshot.cursor)
    }

    /// 新游标 = max(本页事件的最大 seq, 本页 nextCursor)。
    ///
    /// 服务端只在「还有更多事件」时给 nextCursor，所以不能只看它；事件自带的
    /// eventCursor（解码为 ChatMessage.seq）才是权威游标。两者都没有前进时返回 nil，
    /// 由调用方保留旧游标。
    private func advancedCursor(from page: TimelinePage, current: Int) -> Int? {
        var candidate = current
        if let newest = page.events.map({ $0.seq }).max() {
            candidate = max(candidate, newest)
        }
        if let next = page.nextCursor {
            candidate = max(candidate, next)
        }
        return candidate > current ? candidate : nil
    }

    private static func normalized(_ error: Error) -> POSAPIError {
        if let apiError = error as? POSAPIError { return apiError }
        return .transport(error.localizedDescription)
    }
}
