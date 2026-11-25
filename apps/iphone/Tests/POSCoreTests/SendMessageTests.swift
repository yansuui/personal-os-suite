import XCTest
import POSCore

final class SendMessageTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocolStubRegistry.shared.reset() }
    override func tearDown() { URLProtocolStubRegistry.shared.reset(); super.tearDown() }

    func testNewAndReplayShareMessageRunAndIdempotencyKey() async throws {
        var call = 0
        URLProtocolStubRegistry.shared.setHandler { _ in
            call += 1
            return .json(call == 1 ? 201 : 200, Fixtures.sendAck(created: call == 1))
        }
        let api = makeStubAPI()
        let session = try Fixtures.session()
        let pending = PendingMessage(conversationID: Fixtures.conversationID, clientRequestID: "req-1",
                                     text: "hello", createdAt: "2026-01-01T00:00:00.000Z")
        // 模拟重启：从持久化的请求恢复，而不是重新生成 UUID。
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(pending))
        let first = try await api.sendMessage(session, conversationID: pending.conversationID, pending.request)
        let replay = try await api.sendMessage(session, conversationID: restored.conversationID, restored.request)
        XCTAssertTrue(first.created)
        XCTAssertFalse(replay.created)
        XCTAssertEqual(first.message, replay.message)
        XCTAssertEqual(first.run.id, replay.run.id)
        XCTAssertEqual(first.run.status, "queued")
        let requests = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].stubPath, "/v2/conversations/conv-1/messages")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let firstBody = try XCTUnwrap(requests[0].stubBody)
        XCTAssertEqual(firstBody, requests[1].stubBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: firstBody) as? [String: String])
        XCTAssertEqual(body, ["clientRequestId": "req-1", "text": "hello"])
    }

    func testAckWithoutRunFailsAsDecoding() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(201, "{\"message\":\(Fixtures.message()),\"created\":true}")
        }
        do {
            _ = try await makeStubAPI().sendMessage(Fixtures.session(), conversationID: Fixtures.conversationID,
                                                    Fixtures.sendMessageRequest())
            XCTFail("不能伪造缺失的运行")
        } catch let error as POSAPIError {
            guard case .decoding = error else { return XCTFail("应为解码错误") }
        }
    }
}
