import XCTest
import POSCore

final class TimeoutTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocolStubRegistry.shared.reset() }
    override func tearDown() { URLProtocolStubRegistry.shared.reset(); super.tearDown() }

    func testNormalRequestUsesFifteenSecondTimeout() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, "{\"device\":\(Fixtures.deviceJSON)}") }
        _ = try await makeStubAPI().me(Fixtures.session())
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubPath, "/v2/me")
        XCTAssertEqual(request.timeoutInterval, 15, accuracy: 0.001)
    }

    func testLongPollClampsWaitAndKeepsTimeoutMargin() async throws {
        URLProtocolStubRegistry.shared.setHandler { request in
            .json(200, Fixtures.messagePage(nextCursor: Int(request.stubQueryValue("after") ?? "0") ?? 0))
        }
        let api = makeStubAPI()
        let session = try Fixtures.session()
        for wait in [-1, 20, 25, 40] {
            _ = try await api.messages(session, conversationID: Fixtures.conversationID, after: 3, waitSeconds: wait)
        }
        let requests = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(requests.map { $0.stubQueryValue("wait") }, ["0", "20", "25", "25"])
        XCTAssertEqual(requests.map(\.timeoutInterval), [30, 30, 35, 35])
    }
}
