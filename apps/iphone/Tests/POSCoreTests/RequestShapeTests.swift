import XCTest
import POSCore

/// 请求形状：Bearer 头、配对密钥头、审批/验收路径与请求体。
final class RequestShapeTests: XCTestCase {
    private var api: URLSessionPOSAPI!
    private var session: AuthSession!

    override func setUp() {
        super.setUp()
        URLProtocolStubRegistry.shared.reset()
        api = makeStubAPI(baseURL: Fixtures.baseURL)
        session = try? Fixtures.session(token: "secret-token")
    }

    override func tearDown() {
        URLProtocolStubRegistry.shared.reset()
        api = nil
        session = nil
        super.tearDown()
    }

    func testAuthorizedRequestCarriesBearerToken() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"device":{"id":"device-1","name":"iPhone","role":"client","kind":null,"createdAt":"2026-01-01T00:00:00.000Z"}}"#)
        }

        _ = try await api.me(session)

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer secret-token")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testPairUsesPairSecretHeaderAndNoBearer() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(201, """
            {
              "device": {
                "id": "device-1",
                "name": "iPhone",
                "role": "client",
                "kind": null,
                "createdAt": "2026-01-01T00:00:00.000Z"
              },
              "token": "paired-token"
            }
            """)
        }

        let pairRequest = PairRequest(name: "iPhone", role: "client", kind: nil, capabilities: [])
        let paired = try await api.pair(secret: "pair-secret", pairRequest)

        XCTAssertEqual(paired.token, "paired-token")
        XCTAssertEqual(paired.device.id, "device-1")

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.stubPath, "/v1/pair")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-pair-secret"), "pair-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))

        let body = try XCTUnwrap(request.stubBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "iPhone")
        XCTAssertEqual(json["role"] as? String, "client")
        XCTAssertEqual((json["capabilities"] as? [Any])?.count, 0)
    }

    func testApprovePostsToTaskApproveRoute() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"task":{"id":"task-1","status":"running"}}"#)
        }

        try await api.approve(session, taskID: "task-1", approved: true, note: "ok")

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.stubPath, "/v1/tasks/task-1/approve")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer secret-token")

        let body = try XCTUnwrap(request.stubBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["approved"] as? Bool, true)
        XCTAssertEqual(json["note"] as? String, "ok")
    }

    func testSubmitVerdictPostsToVerdictRoute() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"task":{"id":"task-1","verdict":"accepted"}}"#)
        }

        try await api.submitVerdict(session, taskID: "task-1", verdict: "accepted", note: nil)

        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.stubPath, "/v1/tasks/task-1/verdict")

        let body = try XCTUnwrap(request.stubBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["verdict"] as? String, "accepted")
        // note 为 nil 时不下发该键（服务端允许缺省）。
        XCTAssertNil(json["note"])
    }

    func testTasksDecodesServerShapeWithoutCounts() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, """
            {
              "tasks": [
                {
                  "id": "task-1",
                  "uid": "task-abc",
                  "title": "跑测试",
                  "status": "completed",
                  "updatedAt": "2026-01-01T00:00:00.000Z",
                  "requiresApproval": true,
                  "approvedAt": "2026-01-01T00:10:00.000Z",
                  "verdict": "accepted",
                  "outputTail": "ok",
                  "error": null
                }
              ]
            }
            """)
        }

        let list = try await api.tasks(session)

        XCTAssertEqual(list.tasks.count, 1)
        XCTAssertEqual(list.tasks.first?.id, "task-1")
        XCTAssertEqual(list.tasks.first?.requiresApproval, true)
        XCTAssertEqual(list.tasks.first?.verdict, "accepted")
        XCTAssertTrue(list.counts.isEmpty)
    }

    func testContextFlattensServerSnapshots() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, """
            {
              "snapshots": [
                {
                  "kind": "memory",
                  "version": 3,
                  "asOf": "2026-01-01T00:00:00.000Z",
                  "hash": "h",
                  "source": "desktop",
                  "stale": false,
                  "updatedAt": "2026-01-01T00:00:00.000Z",
                  "corrupt": false,
                  "payload": {
                    "available": true,
                    "hits": [
                      {
                        "id": "mem-1",
                        "content": "c",
                        "kind": "fact",
                        "tags": ["t"],
                        "scope": "user",
                        "importance": 2,
                        "workspace": null,
                        "project": null,
                        "updatedAt": "2026-01-01T00:00:00.000Z",
                        "score": 1
                      }
                    ],
                    "noMatch": false
                  }
                },
                {
                  "kind": "plan",
                  "version": 4,
                  "asOf": "2026-01-02T00:00:00.000Z",
                  "hash": "h",
                  "source": "desktop",
                  "stale": false,
                  "updatedAt": "2026-01-02T00:00:00.000Z",
                  "corrupt": false,
                  "payload": {
                    "available": true,
                    "date": "2026-01-02",
                    "items": [
                      {
                        "id": "plan-1",
                        "planDate": "2026-01-02",
                        "title": "写代码",
                        "owner": "me",
                        "startTime": "09:00",
                        "endTime": null,
                        "minutes": 30,
                        "status": "todo",
                        "progress": 0
                      }
                    ]
                  }
                }
              ],
              "checkedAt": "2026-01-02T00:00:00.000Z"
            }
            """)
        }

        let snapshot = try await api.context(session)

        XCTAssertTrue(snapshot.available)
        XCTAssertEqual(snapshot.plan.count, 1)
        XCTAssertEqual(snapshot.plan.first?.id, "plan-1")
        XCTAssertEqual(snapshot.plan.first?.owner, "me")
        XCTAssertEqual(snapshot.memory.count, 1)
        XCTAssertEqual(snapshot.memory.first?.id, "mem-1")
        XCTAssertEqual(snapshot.asOf, "2026-01-02T00:00:00.000Z")
    }

    func testPresenceDecodesOnlineFlags() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(200, #"{"desktopOnline":true,"cloudAgentOnline":false,"queuedChat":2,"queuedTasks":1}"#)
        }

        let presence = try await api.presence(session)

        XCTAssertTrue(presence.desktopOnline)
        XCTAssertFalse(presence.cloudAgentOnline)
        XCTAssertEqual(presence.queuedChat, 2)
    }
}
