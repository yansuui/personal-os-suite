import XCTest
import POSCore

final class RequestShapeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStubRegistry.shared.reset()
    }
    override func tearDown() {
        URLProtocolStubRegistry.shared.reset()
        super.tearDown()
    }

    func testHealthUsesV2WithoutCredentials() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"ok":true,"service":"personal-os-cloud","protocolVersion":2}"#)
        }
        let health = try await makeStubAPI().health()
        XCTAssertEqual(health.protocolVersion, 2)
        XCTAssertNil(health.model)
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubPath, "/v2/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-pair-secret"))
    }

    func testHealthDecodesOptionalModel() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"ok":true,"service":"personal-os-cloud","protocolVersion":2,"model":"provider/model-next"}"#)
        }
        let health = try await makeStubAPI().health()
        XCTAssertEqual(health.model, "provider/model-next")
    }

    func testPairUsesOnlyNameRoleAndPairSecret() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(201, "{\"device\":\(Fixtures.deviceJSON),\"token\":\"paired-token\"}")
        }
        let paired = try await makeStubAPI().pair(secret: "pair-secret", PairRequest(name: "iPhone"))
        XCTAssertEqual(paired.device.role, "client")
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubPath, "/v2/pair")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-pair-secret"), "pair-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
        let body = try XCTUnwrap(request.stubBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["name": "iPhone", "role": "client"])
    }

    func testMeUsesV2BearerWithoutPairSecret() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, "{\"device\":\(Fixtures.deviceJSON)}") }
        let device = try await makeStubAPI().me(Fixtures.session(token: "test-token"))
        XCTAssertEqual(device.id, "device-1")
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubPath, "/v2/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-pair-secret"))
    }

    func testCreateAndListConversationsUseFrozenEnvelopes() async throws {
        URLProtocolStubRegistry.shared.setHandler { request in
            if request.httpMethod == "POST" { return .json(201, "{\"conversation\":\(Fixtures.conversationJSON)}") }
            return .json(200, "{\"conversations\":[\(Fixtures.conversationJSON)]}")
        }
        let api = makeStubAPI()
        let session = try Fixtures.session()
        let created = try await api.createConversation(session, title: "聊天")
        let listed = try await api.conversations(session)
        XCTAssertEqual(listed, [created])
        let requests = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(requests.map(\.stubPath), ["/v2/conversations", "/v2/conversations"])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
        let body = try XCTUnwrap(requests.first?.stubBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["title": "聊天"])
    }

    func testConversationIDCannotEscapeMessageRoute() async throws {
        do {
            _ = try await makeStubAPI().messages(Fixtures.session(), conversationID: "../me", after: 0, waitSeconds: 0)
            XCTFail("无效 ID 应拒绝")
        } catch let error as POSAPIError {
            guard case .decoding = error else { return XCTFail("应为本地校验错误") }
        }
        XCTAssertTrue(URLProtocolStubRegistry.shared.requests.isEmpty)
    }
}
