import Foundation
import XCTest
import POSCore

final class SyncEngineTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocolStubRegistry.shared.reset() }
    override func tearDown() async throws {
        // stop() 结束事件流时，URLSession 仍可能有已排队的 URLProtocol 回调。
        await URLProtocolStubRegistry.shared.invalidateSessions()
        URLProtocolStubRegistry.shared.reset()
        try await super.tearDown()
    }

    func testMessagesThenCursorAndEmptyPageKeepsCursor() async throws {
        let thirdRequest = expectation(description: "空页后继续使用游标 2")
        let thirdResponseGate = DispatchSemaphore(value: 0)
        defer { thirdResponseGate.signal() }
        var calls = 0
        URLProtocolStubRegistry.shared.setHandler { request in
            calls += 1
            if calls == 3 {
                thirdRequest.fulfill()
                // 在第三个长轮询仍在途时停止，避免即时空页抢跑出第四次请求。
                let gateResult = thirdResponseGate.wait(timeout: .now() + 5)
                XCTAssertEqual(gateResult, .success, "第三次响应屏障应由 stop 后主动解除")
            }
            let after = Int(request.stubQueryValue("after") ?? "0") ?? 0
            if after == 0 {
                return .json(200, Fixtures.messagePage(messages: [
                    Fixtures.message(),
                    Fixtures.message(messageID: "assistant-1", seq: 2, role: "assistant", clientRequestID: nil)
                ], nextCursor: 2))
            }
            return .json(200, Fixtures.messagePage(nextCursor: after))
        }
        let engine = SyncEngine(api: makeStubAPI(), session: try Fixtures.session(), conversationID: Fixtures.conversationID,
                                store: MemorySnapshotStore(), waitSeconds: 1)
        let stream = await engine.start()
        let recorder = SyncEventRecorder()
        let consumer = Task { for await event in stream { recorder.append(event) } }
        await fulfillment(of: [thirdRequest], timeout: 5)
        await engine.stop()
        thirdResponseGate.signal()
        await consumer.value
        XCTAssertEqual(recorder.messageIDs, ["m1", "assistant-1"])
        XCTAssertEqual(recorder.firstCursor, 2)
        XCTAssertEqual(recorder.connectedCount, 1)
        let afters = URLProtocolStubRegistry.shared.requests.prefix(3).map { $0.stubQueryValue("after") }
        XCTAssertEqual(afters, ["0", "2", "2"])
        let events = recorder.events
        let messageIndex = try XCTUnwrap(events.firstIndex { if case .messages = $0 { return true }; return false })
        let cursorIndex = try XCTUnwrap(events.firstIndex { if case .cursor = $0 { return true }; return false })
        XCTAssertLessThan(messageIndex, cursorIndex)
        let stoppedCount = URLProtocolStubRegistry.shared.requests.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, stoppedCount)
    }

    func testInitialCursorUsesOnlyRequestedConversation() async throws {
        let received = expectation(description: "收到按会话恢复的请求")
        var first = true
        URLProtocolStubRegistry.shared.setHandler { request in
            if first { first = false; received.fulfill() }
            return .json(200, Fixtures.messagePage(nextCursor: Int(request.stubQueryValue("after") ?? "0") ?? 0))
        }
        let snapshot = CachedSnapshot(savedAt: "2026-01-01T00:00:00Z", cursor: 999,
            selectedConversationID: "other", conversationStates: [
                ConversationSnapshot(conversationID: "other", messages: [], cursor: 22),
                ConversationSnapshot(conversationID: Fixtures.conversationID, messages: [], cursor: 11)
            ])
        let engine = SyncEngine(api: makeStubAPI(), session: try Fixtures.session(), conversationID: Fixtures.conversationID,
                                store: MemorySnapshotStore(snapshot: snapshot), waitSeconds: 1)
        let stream = await engine.start()
        await fulfillment(of: [received], timeout: 5)
        await engine.stop()
        for await _ in stream {}
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.first?.stubQueryValue("after"), "11")
    }

    func testSessionCleanupCancelsQueuedRequestBeforeRegistryReuse() async throws {
        let cancelled = expectation(description: "旧 session 的排队请求已取消")
        let session = makeStubSession()
        let oldRequest = URLRequest(url: URL(string: "http://127.0.0.1:8787/v2/conversations/conv-1/messages?after=0&wait=20")!)
        let queued = session.dataTask(with: oldRequest) { _, _, error in
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
            cancelled.fulfill()
        }
        await URLProtocolStubRegistry.shared.invalidateSessions()
        await fulfillment(of: [cancelled], timeout: 5)

        URLProtocolStubRegistry.shared.reset()
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Fixtures.messagePage(nextCursor: 6)) }
        queued.resume()
        let page = try await makeStubAPI().messages(Fixtures.session(), conversationID: Fixtures.conversationID,
                                                    after: 6, waitSeconds: 20)
        XCTAssertEqual(page.nextCursor, 6)
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.first?.stubQueryValue("after"), "6")
    }

    func testOfflineDoesNotAnnounceConnectedUntilSuccessfulResponse() async throws {
        var call = 0
        URLProtocolStubRegistry.shared.setHandler { _ in
            call += 1
            if call == 1 { return .json(500, #"{"error":{"code":"internal","message":"boom"}}"#) }
            return .json(200, Fixtures.messagePage())
        }
        let engine = SyncEngine(api: makeStubAPI(), session: try Fixtures.session(), conversationID: Fixtures.conversationID,
                                store: MemorySnapshotStore(), waitSeconds: 1)
        let stream = await engine.start()
        let connected = expectation(description: "退避后首次连接成功")
        let recorder = SyncEventRecorder()
        let consumer = Task {
            for await event in stream {
                recorder.append(event)
                if case .connected = event { connected.fulfill() }
            }
        }
        await fulfillment(of: [connected], timeout: 5)
        await engine.stop()
        await consumer.value
        XCTAssertEqual(recorder.connectedCount, 1)
        XCTAssertEqual(recorder.firstDisconnected, .server(status: 500, code: "internal", message: "boom"))
        let firstEvent = try XCTUnwrap(recorder.events.first)
        guard case .disconnected = firstEvent else { return XCTFail("离线时不能假报已连接") }
    }
}
