import XCTest
import POSCore

/// 时间线：eventCursor → seq、source → role、nextCursor 透传。
final class TimelineCursorTests: XCTestCase {
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

    func testTimelineDecodesEventsAndNextCursor() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(
                events: [
                    Fixtures.timelineEvent(messageID: "m1", eventCursor: 5, source: "phone", text: "hello"),
                    Fixtures.timelineEvent(messageID: "m2", eventCursor: 9, source: "assistant", text: "hi")
                ],
                nextCursor: 6
            ))
        }

        let page = try await api.timeline(session, after: 0, waitSeconds: 20)

        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events[0].id, "m1")
        XCTAssertEqual(page.events[0].seq, 5)
        XCTAssertEqual(page.events[0].role, "user")
        XCTAssertEqual(page.events[1].id, "m2")
        XCTAssertEqual(page.events[1].seq, 9)
        XCTAssertEqual(page.events[1].role, "assistant")
        XCTAssertEqual(page.nextCursor, 6)
    }

    func testEmptyTimelinePageHasNoNextCursor() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }

        let page = try await api.timeline(session, after: 6, waitSeconds: 20)

        XCTAssertTrue(page.events.isEmpty)
        XCTAssertNil(page.nextCursor)
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubQueryValue("after"), "6", "空页请求沿用旧游标")
    }

    func testMessageDecodingAcceptsChatShape() async throws {
        // 同一 ChatMessage 也接受 /v1/chat/messages 的字段（id/seq/role）。
        let message = try Fixtures.decode(ChatMessage.self, from: """
        {
          "id": "msg-1",
          "seq": 12,
          "role": "user",
          "text": "hello",
          "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """)

        XCTAssertEqual(message.id, "msg-1")
        XCTAssertEqual(message.seq, 12)
        XCTAssertEqual(message.role, "user")
    }
}
