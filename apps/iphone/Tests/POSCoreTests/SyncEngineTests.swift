import Foundation
import XCTest
import POSCore

final class SyncEngineTests: XCTestCase {
    override func setUp() { super.setUp(); XCTAssertTrue(URLProtocolStubRegistry.shared.reset()) }
    override func tearDown() async throws {
        // stop() 结束事件流时，URLSession 仍可能有已排队的 URLProtocol 回调。
        do {
            try await URLProtocolStubRegistry.shared.invalidateSessions()
        } catch {
            try await super.tearDown()
            throw error
        }
        XCTAssertTrue(URLProtocolStubRegistry.shared.reset())
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
        let cleanupDelegate = try XCTUnwrap(session.delegate as? URLProtocolStubSessionDelegate)
        cleanupDelegate.expectTaskCompletion()
        let oldRequest = URLRequest(url: URL(string: "http://127.0.0.1:8787/v2/conversations/conv-1/messages?after=0&wait=20")!)
        let queued = session.dataTask(with: oldRequest) { _, _, error in
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
            cancelled.fulfill()
            cleanupDelegate.taskCompleted()
        }
        try await URLProtocolStubRegistry.shared.invalidateSessions()
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertTrue(cleanupDelegate.isCleanupComplete)

        XCTAssertTrue(URLProtocolStubRegistry.shared.reset())
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Fixtures.messagePage(nextCursor: 6)) }
        queued.resume()
        let page = try await makeStubAPI().messages(Fixtures.session(), conversationID: Fixtures.conversationID,
                                                    after: 6, waitSeconds: 20)
        XCTAssertEqual(page.nextCursor, 6)
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.first?.stubQueryValue("after"), "6")
    }

    func testSessionCleanupTimeoutPreservesRegistryUntilCallbacksDrain() async {
        let registry = URLProtocolStubRegistry()
        let cleanupDelegate = URLProtocolStubSessionDelegate()
        // 故意不把 delegate 交给 session：它不会自动收到失效回调。
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        registry.trackSession(session, delegate: cleanupDelegate)
        cleanupDelegate.expectTaskCompletion()
        registry.setHandler { _ in .json(200, "{}") }
        _ = registry.respond(to: URLRequest(url: URL(string: "http://stub.invalid/old")!))
        let finished = expectation(description: "缺少回调时清理应有界失败，排空后可恢复")
        let cleanup = Task {
            defer { finished.fulfill() }
            do {
                for invalidated in [false, true] {
                    if invalidated { cleanupDelegate.urlSession(session, didBecomeInvalidWithError: nil) }
                    do {
                        try await registry.invalidateSessions(timeout: 0.05)
                        XCTFail("缺少失效或 completion 回调时不能将清理判为成功")
                        return
                    } catch let error as URLProtocolStubCleanupError {
                        XCTAssertEqual(error.waitResult, .timedOut)
                        XCTAssertEqual(error.invalidated, invalidated)
                        XCTAssertEqual(error.pendingCompletions, 1)
                    }
                    XCTAssertFalse(registry.reset(reportFailure: false), "未排空时必须保留旧注册表")
                    XCTAssertEqual(registry.requests.count, 1)
                }
                cleanupDelegate.taskCompleted()
                try await registry.invalidateSessions(timeout: 1)
                XCTAssertTrue(cleanupDelegate.isCleanupComplete)
                XCTAssertTrue(registry.reset(), "实际排空后应允许恢复复用")
                XCTAssertTrue(registry.requests.isEmpty)
            } catch {
                XCTFail("清理失败类型或恢复结果不符：\(error)")
            }
        }
        defer { cleanup.cancel() }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        guard result == .completed else {
            XCTFail("有界清理未能返回：\(result)")
            return
        }
    }

    func testSessionCleanupWaitsForInvalidationAfterCompletion() async throws {
        let cleanupDelegate = URLProtocolStubSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        cleanupDelegate.expectTaskCompletion()
        cleanupDelegate.taskCompleted()
        XCTAssertFalse(cleanupDelegate.isCleanupComplete)

        do {
            try await cleanupDelegate.waitForInvalidation(timeout: 0.05)
            XCTFail("completion 先返回时仍须等待 session 失效")
        } catch let error as URLProtocolStubCleanupError {
            XCTAssertEqual(error.waitResult, .timedOut)
            XCTAssertFalse(error.invalidated)
            XCTAssertEqual(error.pendingCompletions, 0)
        }

        cleanupDelegate.urlSession(session, didBecomeInvalidWithError: nil)
        try await cleanupDelegate.waitForInvalidation(timeout: 1)
        XCTAssertTrue(cleanupDelegate.isCleanupComplete)
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
