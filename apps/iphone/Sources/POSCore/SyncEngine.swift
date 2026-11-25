import Foundation

public enum SyncEvent: Sendable {
    case connected
    case disconnected(POSAPIError)
    case messages([ChatMessage])
    case cursor(Int)
}

/// 一个实例仅同步一个 conversation，游标从该会话快照恢复。
public actor SyncEngine {
    private let api: POSAPI
    private let session: AuthSession
    private let conversationID: String
    private let store: SnapshotStore
    private let waitSeconds: Int
    private var loopTask: Task<Void, Never>?
    private var continuation: AsyncStream<SyncEvent>.Continuation?
    private var generation = 0

    public init(api: POSAPI, session: AuthSession, conversationID: String,
                store: SnapshotStore, waitSeconds: Int = 20) {
        self.api = api
        self.session = session
        self.conversationID = conversationID
        self.store = store
        self.waitSeconds = min(25, max(0, waitSeconds))
    }

    public func start() -> AsyncStream<SyncEvent> {
        stop()
        generation += 1
        let streamGeneration = generation
        // 消息和游标必须一并消费，不能通过丢弃旧事件使快照跳过消息。
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.handleTermination(streamGeneration) }
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(continuation: continuation)
        }
        return stream
    }

    public func stop() {
        generation += 1
        loopTask?.cancel()
        loopTask = nil
        let pending = continuation
        continuation = nil
        pending?.finish()
    }

    private func handleTermination(_ streamGeneration: Int) {
        guard generation == streamGeneration else { return }
        stop()
    }

    private func runLoop(continuation: AsyncStream<SyncEvent>.Continuation) async {
        var cursor = initialCursor()
        var backoffSeconds = 1
        var connected = false
        while !Task.isCancelled {
            do {
                let page = try await api.messages(session, conversationID: conversationID,
                                                  after: cursor, waitSeconds: waitSeconds)
                if Task.isCancelled { break }
                if !connected {
                    continuation.yield(.connected)
                    connected = true
                }
                backoffSeconds = 1
                if !page.messages.isEmpty {
                    continuation.yield(.messages(page.messages))
                    if page.nextCursor > cursor {
                        cursor = page.nextCursor
                        continuation.yield(.cursor(cursor))
                    }
                }
                // v2 空页 nextCursor 等于请求 after，保持本地游标。
            } catch {
                if Task.isCancelled { break }
                let failure = (error as? POSAPIError) ?? .transport(error.localizedDescription)
                continuation.yield(.disconnected(failure))
                connected = false
                if case .unauthorized = failure { break }
                let delay = backoffSeconds
                backoffSeconds = min(backoffSeconds * 2, 30)
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                catch { break }
            }
        }
        continuation.finish()
    }

    private func initialCursor() -> Int {
        guard let snapshot = try? store.loadSnapshot() else { return 0 }
        return max(0, snapshot.conversationStates.first {
            $0.conversationID == conversationID
        }?.cursor ?? 0)
    }
}
