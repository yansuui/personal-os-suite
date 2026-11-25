import XCTest
import POSCore

final class TimelineCursorTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocolStubRegistry.shared.reset() }
    override func tearDown() { URLProtocolStubRegistry.shared.reset(); super.tearDown() }

    func testMessagesDecodeUserAndAssistantWithSharedSequence() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.messagePage(messages: [
                Fixtures.message(messageID: "user-1", seq: 1),
                Fixtures.message(messageID: "assistant-1", seq: 2, role: "assistant", clientRequestID: nil)
            ], nextCursor: 2))
        }
        let page = try await makeStubAPI().messages(Fixtures.session(), conversationID: Fixtures.conversationID,
                                                    after: 0, waitSeconds: 20)
        XCTAssertEqual(page.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(page.messages.map(\.seq), [1, 2])
        XCTAssertEqual(page.messages[1].conversationID, "conv-1")
        XCTAssertNil(page.messages[1].clientRequestID)
        XCTAssertEqual(page.nextCursor, 2)
    }

    func testEmptyPageKeepsRequestCursor() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Fixtures.messagePage(nextCursor: 6)) }
        let page = try await makeStubAPI().messages(Fixtures.session(), conversationID: Fixtures.conversationID,
                                                    after: 6, waitSeconds: 20)
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.nextCursor, 6)
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubQueryValue("after"), "6")
    }

    func testWrongConversationCannotEnterSnapshot() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.messagePage(messages: [Fixtures.message(conversationID: "other")], nextCursor: 1))
        }
        do {
            _ = try await makeStubAPI().messages(Fixtures.session(), conversationID: Fixtures.conversationID,
                                                 after: 0, waitSeconds: 0)
            XCTFail("其它会话的数据必须拒绝")
        } catch let error as POSAPIError {
            guard case .decoding = error else { return XCTFail("应为解码错误") }
        }
    }
}
