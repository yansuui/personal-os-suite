import XCTest
import POSCore

/// 分档超时：普通请求 15s；长轮询按 waitSeconds + 10 计算，且不低于 30s。
final class TimeoutTests: XCTestCase {
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

    func testNormalRequestUsesFifteenSecondTimeout() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"device":{"id":"device-1","name":"iPhone","role":"client","kind":null,"createdAt":"2026-01-01T00:00:00.000Z"}}"#)
        }

        _ = try await api.me(session)

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubPath, "/v1/me")
        XCTAssertEqual(request.timeoutInterval, 15, accuracy: 0.001)
    }

    func testTimelineLongPollUsesAtLeastThirtySecondTimeout() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }

        _ = try await api.timeline(session, after: 0, waitSeconds: 20)

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.timeoutInterval, 30, accuracy: 0.001)
        XCTAssertEqual(request.stubQueryValue("after"), "0")
        XCTAssertEqual(request.stubQueryValue("wait"), "20")
    }

    func testTimelineTimeoutGrowsWithWaitSeconds() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, Fixtures.timelinePage(events: [], nextCursor: nil))
        }

        // waitSeconds 0：仍取下限 30s。
        _ = try await api.timeline(session, after: 3, waitSeconds: 0)
        // waitSeconds 40：max(30, 50) = 50s。
        _ = try await api.timeline(session, after: 3, waitSeconds: 40)

        let requests = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].timeoutInterval, 30, accuracy: 0.001)
        XCTAssertEqual(requests[1].timeoutInterval, 50, accuracy: 0.001)
        XCTAssertEqual(requests[1].stubQueryValue("after"), "3")
        XCTAssertEqual(requests[1].stubQueryValue("wait"), "40")
    }
}
