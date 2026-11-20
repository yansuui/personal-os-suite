import XCTest
import POSCore

/// SyncEngine：首推 .connected、消息后推 .cursor、空页保持旧游标、断线退避重连、stop 结束流。
final class SyncEngineTests: XCTestCase {
    private var api: URLSessionPOSAPI!
    private var session: AuthSession!

    override func setUp() {
        super.setUp()
        URLProtocolStubRegistry.shared.reset()
        api = makeStubAPI(baseURL: Fixtures.baseURL)
        session = try? Fixtures.session()
    }

    override func tearDown() {
        URLProtocolStubRegistry.shared.reset()
        api = nil
        session = nil
        super.tearDown()
    }

    func testStartYieldsConnectedAndStopEndsStream() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }
        let engine = SyncEngine(api: api, session: session, store: MemorySnapshotStore(), waitSeconds: 1)
        let stream = await engine.start()
        let recorder = SyncEventRecorder()

        let connected = expectation(description: "收到 connected")
        let finished = expectation(description: "流已结束")
        let collector = Task {
            var connectedSeen = false
            for await event in stream {
                recorder.append(event)
                if case .connected = event, !connectedSeen {
                    connectedSeen = true
                    connected.fulfill()
                }
            }
            finished.fulfill()
        }

        await fulfillment(of: [connected], timeout: 5)
        await engine.stop()
        await fulfillment(of: [finished], timeout: 5)
        await collector.value

        XCTAssertEqual(recorder.connectedCount, 1, "首推只应有一个 connected")
        try await Task.sleep(nanoseconds: 100_000_000)
        let settledCount = URLProtocolStubRegistry.shared.requests.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, settledCount, "stop() 后不得再发请求")
    }

    func testMessagesThenCursorForNonEmptyPage() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(
                events: [Fixtures.timelineEvent(messageID: "m1", eventCursor: 5)],
                nextCursor: nil
            ))
        }
        let engine = SyncEngine(api: api, session: session, store: MemorySnapshotStore(), waitSeconds: 1)
        let stream = await engine.start()
        let recorder = SyncEventRecorder()

        let cursorReached = expectation(description: "收到 cursor")
        let collector = Task {
            for await event in stream {
                recorder.append(event)
                if case .cursor = event { cursorReached.fulfill() }
            }
        }

        await fulfillment(of: [cursorReached], timeout: 5)
        await engine.stop()
        await collector.value

        let events = recorder.events
        XCTAssertEqual(recorder.connectedCount, 1)
        XCTAssertEqual(recorder.messageIDs, ["m1"])
        // 服务端只在「还有更多」时给 nextCursor；这里没有，游标必须由事件 eventCursor 推进。
        XCTAssertEqual(recorder.firstCursor, 5)

        let messagesIndex = events.firstIndex { event in
            if case .messages = event { return true }
            return false
        }
        let cursorIndex = events.firstIndex { event in
            if case .cursor = event { return true }
            return false
        }
        let connectedIndex = events.firstIndex { event in
            if case .connected = event { return true }
            return false
        }
        XCTAssertEqual(connectedIndex, 0)
        if let messagesIndex, let cursorIndex {
            XCTAssertLessThan(messagesIndex, cursorIndex, "先推 messages 再推 cursor")
        } else {
            XCTFail("缺少 messages 或 cursor 事件")
        }
    }

    func testEmptyPageKeepsPreviousCursor() async throws {
        var call = 0
        URLProtocolStubRegistry.shared.setHandler { _ in
            call += 1
            if call == 1 {
                return .json(200, Fixtures.timelinePage(
                    events: [Fixtures.timelineEvent(messageID: "m1", eventCursor: 5)],
                    nextCursor: 6
                ))
            }
            return .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }
        let engine = SyncEngine(api: api, session: session, store: MemorySnapshotStore(), waitSeconds: 1)
        let stream = await engine.start()
        let recorder = SyncEventRecorder()

        let cursorReached = expectation(description: "游标推进到 6")
        let collector = Task {
            for await event in stream {
                recorder.append(event)
                if case .cursor = event, recorder.firstCursor == 6 {
                    cursorReached.fulfill()
                }
            }
        }

        await fulfillment(of: [cursorReached], timeout: 5)

        // 空页会继续发请求，前三个请求的 after 应为 0 → 6 → 6（空页不重置游标）。
        var waited = 0
        while URLProtocolStubRegistry.shared.requests.count < 3 && waited < 3_000 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 20
        }
        await engine.stop()
        await collector.value

        XCTAssertEqual(recorder.firstCursor, 6)
        let afters = URLProtocolStubRegistry.shared.requests.compactMap { $0.stubQueryValue("after") }
        XCTAssertGreaterThanOrEqual(afters.count, 3)
        XCTAssertEqual(afters[0], "0")
        XCTAssertEqual(afters[1], "6")
        XCTAssertEqual(afters[2], "6")
    }

    func testDisconnectedThenReconnects() async throws {
        var call = 0
        URLProtocolStubRegistry.shared.setHandler { _ in
            call += 1
            if call == 1 {
                return .json(500, #"{"error":{"code":"internal","message":"boom"}}"#)
            }
            return .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }
        let engine = SyncEngine(api: api, session: session, store: MemorySnapshotStore(), waitSeconds: 1)
        let stream = await engine.start()
        let recorder = SyncEventRecorder()

        let disconnected = expectation(description: "收到 disconnected")
        let reconnected = expectation(description: "重连后再次 connected")
        let collector = Task {
            var connectedCount = 0
            var disconnectedCount = 0
            for await event in stream {
                recorder.append(event)
                switch event {
                case .connected:
                    connectedCount += 1
                    if connectedCount == 2 { reconnected.fulfill() }
                case .disconnected:
                    disconnectedCount += 1
                    if disconnectedCount == 1 { disconnected.fulfill() }
                case .messages, .cursor:
                    break
                }
            }
        }

        await fulfillment(of: [disconnected], timeout: 5)
        await fulfillment(of: [reconnected], timeout: 10)
        await engine.stop()
        await collector.value

        XCTAssertEqual(
            recorder.firstDisconnected,
            .server(status: 500, code: "internal", message: "boom")
        )
        XCTAssertGreaterThanOrEqual(recorder.connectedCount, 2, "重连成功后应重新推 connected")
    }

    func testInitialCursorComesFromCachedSnapshot() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }
        let snapshot = CachedSnapshot(
            savedAt: "2026-01-01T00:00:00.000Z",
            timeline: [],
            cursor: 11,
            tasks: [],
            context: nil
        )
        let engine = SyncEngine(
            api: api,
            session: session,
            store: MemorySnapshotStore(snapshot: snapshot),
            waitSeconds: 1
        )
        let stream = await engine.start()

        var waited = 0
        while URLProtocolStubRegistry.shared.requests.isEmpty && waited < 3_000 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 20
        }
        await engine.stop()
        for await _ in stream {}

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubQueryValue("after"), "11")
    }

    func testResendPendingDoesNotThrowWithoutSnapshot() async throws {
        let store = MemorySnapshotStore()
        let engine = SyncEngine(api: api, session: session, store: store, waitSeconds: 1)

        await engine.resendPending()

        XCTAssertEqual(store.saveCount, 0)
        XCTAssertTrue(URLProtocolStubRegistry.shared.requests.isEmpty, "没有待发消息时不得发请求")
    }
}
