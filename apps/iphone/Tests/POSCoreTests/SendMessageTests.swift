import XCTest
import POSCore

/// 幂等：同一个 SendMessageRequest 重试两次，必须发出完全相同的请求体（clientRequestId 不变）。
final class SendMessageTests: XCTestCase {
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

    func testSendMessageRetryReusesClientRequestID() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(201, #"{"message":{"id":"msg-1","seq":7},"duplicate":false}"#)
        }

        let request = try Fixtures.sendMessageRequest(clientRequestID: "req-1", text: "hello")

        let first = try await api.sendMessage(session, request)
        let second = try await api.sendMessage(session, request)

        XCTAssertEqual(first.messageID, "msg-1")
        XCTAssertNil(first.runID)
        XCTAssertEqual(second.messageID, "msg-1")

        let recorded = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[0].stubPath, "/v1/chat/messages")
        XCTAssertEqual(recorded[0].httpMethod, "POST")

        let firstBody = try XCTUnwrap(recorded[0].stubBody)
        let secondBody = try XCTUnwrap(recorded[1].stubBody)
        XCTAssertEqual(firstBody, secondBody, "重试必须复用同一 clientRequestID，请求体逐字节一致")

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        XCTAssertEqual(json["clientRequestId"] as? String, "req-1")
        XCTAssertEqual(json["text"] as? String, "hello")
        // conversationID 为 nil 时不下发该键。
        XCTAssertNil(json["conversationId"])
    }

    func testDuplicateAckStillCarriesMessageID() async throws {
        // 服务端幂等重放返回 200 + duplicate: true，ack 语义不变。
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"message":{"id":"msg-1"},"duplicate":true}"#)
        }

        let request = try Fixtures.sendMessageRequest()
        let ack = try await api.sendMessage(session, request)

        XCTAssertEqual(ack.messageID, "msg-1")
    }

    func testAckWithoutMessageBodyFailsAsDecoding() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(201, #"{"duplicate":false}"#)
        }

        let request = try Fixtures.sendMessageRequest()
        do {
            _ = try await api.sendMessage(session, request)
            XCTFail("缺少 message 时应抛 .decoding")
        } catch let error as POSAPIError {
            guard case .decoding = error else {
                return XCTFail("期望 .decoding，实际 \(error)")
            }
        }
    }
}
