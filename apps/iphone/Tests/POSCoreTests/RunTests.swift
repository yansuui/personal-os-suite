import Foundation
import XCTest
import POSCore

final class RunTests: XCTestCase {
    private enum Endpoint: CaseIterable {
        case run
        case cancel
    }

    override func setUp() {
        super.setUp()
        URLProtocolStubRegistry.shared.reset()
    }

    override func tearDown() {
        URLProtocolStubRegistry.shared.reset()
        super.tearDown()
    }

    func testRunUsesAuthenticatedGETWithEmptyBodyAndFifteenSecondTimeout() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Self.runEnvelope(status: "running")) }
        let api = makeStubAPI(baseURL: URL(string: "http://127.0.0.1:8787/api/")!)
        let run = try await api.run(Fixtures.session(), runID: "run-1")

        XCTAssertEqual(run.id, "run-1")
        XCTAssertEqual(run.conversationId, "conv-1")
        XCTAssertEqual(run.messageId, "m1")
        XCTAssertEqual(run.status, "running")
        XCTAssertNil(run.error)
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        assertRequest(request, method: "GET", path: "/api/v2/runs/run-1")
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
    }

    func testCancelUsesAuthenticatedPOSTWithEmptyBodyAndReturnsCanceledRun() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Self.runEnvelope(status: "canceled")) }
        let run = try await makeStubAPI().cancelRun(Fixtures.session(), runID: "run-1")

        XCTAssertEqual(run.id, "run-1")
        XCTAssertEqual(run.status, "canceled")
        let request = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        assertRequest(request, method: "POST", path: "/v2/runs/run-1/cancel")
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
    }

    func testCancelPreservesAnAlreadyCompletedRun() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Self.runEnvelope(status: "completed")) }
        let run = try await makeStubAPI().cancelRun(Fixtures.session(), runID: "run-1")
        XCTAssertEqual(run.status, "completed", "取消已终态运行必须保留服务器返回的状态")
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
    }

    func testRunAcceptsEveryFrozenStatusAndPreservesServerFailure() async throws {
        let api = makeStubAPI()
        let session = try Fixtures.session()
        for status in ["queued", "running", "completed", "failed", "canceled"] {
            URLProtocolStubRegistry.shared.setHandler { _ in
                .json(200, Self.runEnvelope(status: status, errorJSON: status == "failed" ? "\"Model request timed out.\"" : "null"))
            }
            let run = try await api.run(session, runID: "run-1")
            XCTAssertEqual(run.status, status)
            XCTAssertEqual(run.error, status == "failed" ? "Model request timed out." : nil)
        }
    }

    func testInvalidRunIDsAreRejectedBeforeEitherEndpointSendsARequest() async throws {
        let api = makeStubAPI()
        let session = try Fixtures.session()
        for endpoint in Endpoint.allCases {
            for id in ["", " ", "../me", "run/1", "run\\1", "run%2F1", "run?after=1", "run#fragment", "运行"] {
                await assertDecoding { try await self.call(endpoint, api: api, session: session, runID: id) }
            }
        }
        XCTAssertTrue(URLProtocolStubRegistry.shared.requests.isEmpty)
    }

    func testMismatchedRunAndInvalidRelatedIDsAreRejectedByBothEndpoints() async throws {
        let api = makeStubAPI()
        let session = try Fixtures.session()
        let bodies = [
            Self.runEnvelope(id: "other-run"),
            Self.runEnvelope(conversationID: "../conversation"),
            Self.runEnvelope(messageID: "message/1")
        ]
        for endpoint in Endpoint.allCases {
            for body in bodies {
                URLProtocolStubRegistry.shared.setHandler { _ in .json(200, body) }
                await assertDecoding { try await self.call(endpoint, api: api, session: session) }
            }
        }
    }

    func testUnknownStatusIsRejectedByBothEndpoints() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Self.runEnvelope(status: "paused")) }
        let api = makeStubAPI()
        let session = try Fixtures.session()
        for endpoint in Endpoint.allCases {
            await assertDecoding { try await self.call(endpoint, api: api, session: session) }
        }
    }

    func testMalformedSuccessResponsesDoNotInventARun() async throws {
        let api = makeStubAPI()
        let session = try Fixtures.session()
        for endpoint in Endpoint.allCases {
            for body in ["{", #"{"run":null}"#, #"{"id":"run-1","status":"running"}"#,
                         #"{"run":{"id":"run-1","conversationId":"conv-1","status":"running"}}"#] {
                URLProtocolStubRegistry.shared.setHandler { _ in .json(200, body) }
                await assertDecoding { try await self.call(endpoint, api: api, session: session) }
            }
        }
    }

    func testBothEndpointsMapAuthenticationErrorsWithoutRetrying() async throws {
        let api = makeStubAPI()
        let session = try Fixtures.session()
        for endpoint in Endpoint.allCases {
            for status in [401, 403] {
                URLProtocolStubRegistry.shared.reset()
                URLProtocolStubRegistry.shared.setHandler { _ in
                    .json(status, #"{"error":{"code":"unauthorized","message":"Authentication required."}}"#)
                }
                await assertAPIError(.unauthorized) { try await self.call(endpoint, api: api, session: session) }
                XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
            }
        }
    }

    func testBothEndpointsPreserveNotFoundAndConflictWithoutRetrying() async throws {
        let api = makeStubAPI()
        let session = try Fixtures.session()
        let failures: [(Int, String, POSAPIError)] = [
            (404, #"{"error":{"code":"not_found","message":"Run not found."}}"#,
             .server(status: 404, code: "not_found", message: "Run not found.")),
            (409, #"{"error":{"code":"conflict","message":"Refresh the run."}}"#, .conflict("Refresh the run."))
        ]
        for endpoint in Endpoint.allCases {
            for (status, body, expected) in failures {
                URLProtocolStubRegistry.shared.reset()
                URLProtocolStubRegistry.shared.setHandler { _ in .json(status, body) }
                await assertAPIError(expected) { try await self.call(endpoint, api: api, session: session) }
                XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 1)
            }
        }
    }

    func testClientRunEncodingDropsServerLeaseFields() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, Self.runEnvelope(status: "running")) }
        let run = try await makeStubAPI().run(Fixtures.session(), runID: "run-1")
        let encoded = try JSONEncoder().encode(run)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "conversationId", "messageId", "status"]))
        XCTAssertNil(object["leaseToken"])
        XCTAssertNil(object["leasedUntil"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-test-lease"))
    }

    func testFileSnapshotRestoresRunStatesAndErrorsWithoutLeaseMetadata() throws {
        let records = [
            RunRecord(runID: "run-running", conversationID: "conv-1", messageID: "m1", status: .running,
                      pollingError: "Temporarily offline.", cancellationError: "Cancellation not confirmed."),
            RunRecord(runID: "run-failed", conversationID: "conv-1", messageID: "m2", status: .failed,
                      serverError: "Model request timed out.")
        ]
        let snapshot = CachedSnapshot(savedAt: "2026-01-01T00:00:00Z", selectedConversationID: "conv-1", runRecords: records)
        try withSnapshotStore { store, file in
            try store.saveSnapshot(snapshot)
            let restored = try XCTUnwrap(try FileSnapshotStore(directory: file.deletingLastPathComponent()).loadSnapshot())
            XCTAssertEqual(restored, snapshot)
            XCTAssertEqual(restored.runRecords, records)
            let data = try Data(contentsOf: file)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let savedRecords = try XCTUnwrap(object["runRecords"] as? [[String: Any]])
            XCTAssertEqual(savedRecords.count, 2)
            for record in savedRecords {
                XCTAssertNil(record["leaseToken"])
                XCTAssertNil(record["leasedUntil"])
            }
        }
    }

    func testSnapshotsWithoutRunRecordsRestoreAnEmptyRunList() throws {
        let oldSnapshots = [
            #"{"savedAt":"2026-01-01T00:00:00Z","timeline":[],"cursor":7,"tasks":[]}"#,
            """
            {"savedAt":"2026-01-01T00:00:00Z","conversations":[\(Fixtures.conversationJSON)],
             "selectedConversationID":"conv-1","conversationStates":[{"conversationID":"conv-1","messages":[],"cursor":0}],
             "pendingMessages":[{"conversationID":"conv-1","clientRequestID":"persistent-key","text":"offline","createdAt":"now"}]}
            """
        ]
        try withSnapshotStore { store, file in
            for json in oldSnapshots {
                try Data(json.utf8).write(to: file, options: .atomic)
                let restored = try XCTUnwrap(try store.loadSnapshot())
                XCTAssertTrue(restored.runRecords.isEmpty)
                if restored.selectedConversationID != nil {
                    XCTAssertEqual(restored.selectedConversationID, "conv-1")
                    XCTAssertEqual(restored.pendingMessages.first?.clientRequestID, "persistent-key")
                } else {
                    XCTAssertEqual(restored.cursor, 7)
                }
                try store.saveSnapshot(restored)
                XCTAssertEqual(try store.loadSnapshot(), restored)
            }
        }
    }

    private static func runEnvelope(id: String = "run-1", conversationID: String = "conv-1",
                                    messageID: String = "m1", status: String = "queued", errorJSON: String = "null") -> String {
        """
        {"run":{"id":"\(id)","conversationId":"\(conversationID)","messageId":"\(messageID)",
         "status":"\(status)","error":\(errorJSON),"leaseToken":"private-test-lease",
         "leasedUntil":"2026-01-01T00:01:00Z","createdAt":"2026-01-01T00:00:00Z"}}
        """
    }

    private func call(_ endpoint: Endpoint, api: URLSessionPOSAPI, session: AuthSession, runID: String = "run-1") async throws -> Run {
        switch endpoint {
        case .run: return try await api.run(session, runID: runID)
        case .cancel: return try await api.cancelRun(session, runID: runID)
        }
    }

    private func assertRequest(_ request: URLRequest, method: String, path: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertEqual(request.stubPath, path, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test-token", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "application/json", file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-pair-secret"), file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "content-type"), file: file, line: line)
        XCTAssertTrue(request.stubBody?.isEmpty ?? true, "请求体必须为空，不能发送 status 或 leaseToken", file: file, line: line)
        XCTAssertTrue(request.stubQueryItems.isEmpty, file: file, line: line)
        XCTAssertEqual(request.timeoutInterval, 15, accuracy: 0.001, file: file, line: line)
    }

    private func assertDecoding(file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () async throws -> Run) async {
        do {
            _ = try await operation()
            XCTFail("应拒绝无效运行 ID 或响应", file: file, line: line)
        } catch let error as POSAPIError {
            guard case .decoding = error else {
                return XCTFail("期望 .decoding，实际 \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("期望 POSAPIError，实际 \(error)", file: file, line: line)
        }
    }

    private func assertAPIError(_ expected: POSAPIError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () async throws -> Run) async {
        do {
            _ = try await operation()
            XCTFail("失败响应应抛错", file: file, line: line)
        } catch let error as POSAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("期望 POSAPIError，实际 \(error)", file: file, line: line)
        }
    }

    private func withSnapshotStore(_ body: (FileSnapshotStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("POSCoreRunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(FileSnapshotStore(directory: directory), directory.appendingPathComponent("snapshot.json"))
    }
}
