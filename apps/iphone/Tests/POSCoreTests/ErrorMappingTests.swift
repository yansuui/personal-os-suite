import XCTest
import POSCore

/// 错误映射：401/403 → .unauthorized，409 → .conflict（且不重试），
/// 其它非 2xx → .server(status:code:message:)，坏 JSON → .decoding。
final class ErrorMappingTests: XCTestCase {
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

    func testUnauthorizedMapsToUnauthorized() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(401, #"{"error":{"code":"unauthorized","message":"需要有效的设备 token"}}"#)
        }

        do {
            _ = try await api.me(session)
            XCTFail("401 应抛错")
        } catch let error as POSAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testForbiddenMapsToUnauthorized() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(403, #"{"error":{"code":"forbidden","message":"需要 client 角色"}}"#)
        }

        do {
            _ = try await api.me(session)
            XCTFail("403 应抛错")
        } catch let error as POSAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testConflictMapsToConflictAndIsNotRetried() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(409, #"{"error":{"code":"idempotency-conflict","message":"requestId 已被其它正文占用"}}"#)
        }

        let request = try Fixtures.sendMessageRequest(clientRequestID: "req-9", text: "hello")
        do {
            _ = try await api.sendMessage(session, conversationID: Fixtures.conversationID, request)
            XCTFail("409 应抛错")
        } catch let error as POSAPIError {
            XCTAssertEqual(error, .conflict("requestId 已被其它正文占用"))
        }

        // 409 不覆盖、不重试：网络层只发一次请求。
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
    }

    func testServerErrorCarriesParsedCodeAndMessage() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(500, #"{"error":{"code":"internal","message":"internal error"}}"#)
        }

        do {
            _ = try await api.me(session)
            XCTFail("500 应抛错")
        } catch let error as POSAPIError {
            XCTAssertEqual(error, .server(status: 500, code: "internal", message: "internal error"))
        }
    }

    func testServerErrorFallsBackToDefaultsWhenBodyIsNotJSON() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            StubResponse(status: 502, headers: ["content-type": "text/plain"], body: Data("bad gateway".utf8))
        }

        do {
            _ = try await api.me(session)
            XCTFail("502 应抛错")
        } catch let error as POSAPIError {
            guard case let .server(status, code, message) = error else {
                return XCTFail("期望 .server，实际 \(error)")
            }
            XCTAssertEqual(status, 502)
            XCTAssertEqual(code, "http-502")
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testPublicHealthAuthOrMissingRouteReportsV2Unavailable() async throws {
        for status in [401, 403, 404] {
            URLProtocolStubRegistry.shared.reset()
            URLProtocolStubRegistry.shared.setHandler { _ in
                .json(status, #"{"error":{"code":"unauthorized","message":"需要有效的设备 token"}}"#)
            }

            do {
                _ = try await api.health()
                XCTFail("公开 health 返回 \(status) 应提示 v2 不可用")
            } catch let error as POSAPIError {
                guard case let .server(actualStatus, code, message) = error else {
                    return XCTFail("服务不兼容不能误报为配对密钥错误，实际 \(error)")
                }
                XCTAssertEqual(actualStatus, status)
                XCTAssertEqual(code, "v2_unavailable")
                XCTAssertTrue(message.contains("v2"))
            }
            let requests = URLProtocolStubRegistry.shared.requests
            XCTAssertEqual(requests.count, 1, "不能向旧版接口自动回退")
            XCTAssertEqual(requests.first?.stubPath, "/v2/health")
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "x-pair-secret"))
        }
    }

    func testHealthServerFailureRetainsItsActualError() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(503, #"{"error":{"code":"maintenance","message":"Try later"}}"#)
        }
        do {
            _ = try await api.health()
            XCTFail("503 应抛错")
        } catch let error as POSAPIError {
            XCTAssertEqual(error, .server(status: 503, code: "maintenance", message: "Try later"))
        }
    }

    func testMissingConversationRetainsNotFoundError() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(404, #"{"error":{"code":"not_found","message":"Conversation not found."}}"#)
        }
        do {
            _ = try await api.messages(session, conversationID: Fixtures.conversationID, after: 0, waitSeconds: 0)
            XCTFail("会话不存在应抛错")
        } catch let error as POSAPIError {
            XCTAssertEqual(error, .server(status: 404, code: "not_found", message: "Conversation not found."))
        }
    }

    func testMalformedSuccessBodyMapsToDecoding() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"unexpected":true}"#)
        }

        do {
            _ = try await api.me(session)
            XCTFail("坏响应应抛错")
        } catch let error as POSAPIError {
            guard case .decoding = error else {
                return XCTFail("期望 .decoding，实际 \(error)")
            }
        }
    }
}
