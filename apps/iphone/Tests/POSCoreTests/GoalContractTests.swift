import Foundation
import XCTest
import POSCore

final class GoalContractTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocolStubRegistry.shared.reset() }
    override func tearDown() { URLProtocolStubRegistry.shared.reset(); super.tearDown() }

    func testGoalUpdateDistinguishesOmittedAndExplicitNullFields() throws {
        let command = GoalCommand(commandId: "goal-edit", expectedRevision: 3, action: .update,
            description: .null, successCriteria: .null, targetDate: .null)
        let body = try json(command)
        XCTAssertNil(body["title"])
        for key in ["description", "successCriteria", "targetDate"] { XCTAssertTrue(body[key] is NSNull, key) }
        XCTAssertEqual(try roundTrip(command), command)
        let omitted = try json(GoalCommand(commandId: "partial", expectedRevision: 3, action: .update, title: "新标题"))
        for key in ["description", "successCriteria", "targetDate"] { XCTAssertNil(omitted[key], key) }
    }

    func testTaskUpdateCanClearDescriptionAndDate() throws {
        let command = GoalTaskCommand(commandId: "task-edit", expectedRevision: 4, action: .update,
            description: .null, dueDate: .null)
        let body = try json(command)
        XCTAssertTrue(body["description"] is NSNull)
        XCTAssertTrue(body["dueDate"] is NSNull)
        XCTAssertNil(body["note"])
        XCTAssertEqual(try roundTrip(command), command)
    }

    func testBlockedCommandUsesNoteWithoutUnknownOrUpdateFields() throws {
        let command = GoalTaskCommand(commandId: "block", expectedRevision: 2, action: .setStatus,
            title: "不会编码", description: .value("不会编码"), dueDate: .null, status: .blocked, note: "等待答复")
        let body = try json(command)
        XCTAssertEqual(Set(body.keys), Set(["commandId", "expectedRevision", "action", "status", "note"]))
        XCTAssertEqual(body["note"] as? String, "等待答复")
        XCTAssertNil(body["blockedReason"])
        let progress = try json(GoalTaskCommand(expectedRevision: 2, action: .progress,
            status: .completed, note: "新进展", resultNote: "不会编码"))
        XCTAssertNil(progress["status"])
        XCTAssertNil(progress["resultNote"])
    }

    func testGoalStateCommandOnlyEncodesActionAndRevision() throws {
        let body = try json(GoalCommand(commandId: "archive", expectedRevision: 2, action: .archive,
            title: "不会编码", description: .null, successCriteria: .null, targetDate: .null))
        XCTAssertEqual(Set(body.keys), Set(["commandId", "expectedRevision", "action"]))
    }

    func testCapabilityGateAndLegacyPendingAndRunRemainCompatible() throws {
        let old = try Fixtures.decode(POSCapabilities.self, from: #"{"goalsTasksVersion":1}"#)
        XCTAssertTrue(old.supportsGoals)
        XCTAssertFalse(old.supportsGoalQuestions)
        XCTAssertFalse(POSCapabilities(goalsTasksVersion: 1, goalQuestionsVersion: 0).supportsGoalQuestions)
        XCTAssertTrue(POSCapabilities(goalsTasksVersion: 1, goalQuestionsVersion: 1).supportsGoalQuestions)
        let pending = try Fixtures.decode(PendingMessage.self, from: #"{"conversationID":"conv-1","clientRequestID":"legacy","text":"保留原正文","createdAt":"now"}"#)
        XCTAssertNil(pending.goalID)
        let run = try Fixtures.decode(Run.self, from: #"{"id":"run-1","conversationId":"conv-1","messageId":"m1","status":"queued"}"#)
        XCTAssertNil(run.goalId)
        let associated = PendingMessage(conversationID: "conv-1", clientRequestID: "fixed", text: "还剩什么", createdAt: "now", goalID: "goal-1")
        XCTAssertEqual(try roundTrip(associated), associated)
    }

    func testDraftRoundTripKeepsExactCommandIncludingNullAndExpectedRevision() throws {
        var draft = GoalDraft(id: "edit", kind: .editGoal, goalID: "goal-1", expectedRevision: 7,
            title: "本地标题", description: "", successCriteria: "", date: "")
        draft.mutation = try XCTUnwrap(draft.makeMutation(commandID: "persistent-command"))
        draft.state = .unconfirmed
        let cache = CachedSnapshot(savedAt: "now", identityKey: "https://server.invalid|device-1",
            goalCache: GoalCache(lastSyncedAt: "server-read-time", drafts: [draft]))
        let restored = try roundTrip(cache)
        XCTAssertEqual(restored.goalCache.drafts.first, draft)
        XCTAssertEqual(restored.goalCache.drafts.first?.mutation?.commandID, "persistent-command")
        guard case .goal(_, let command) = try XCTUnwrap(restored.goalCache.drafts.first?.mutation) else { return XCTFail("wrong intent") }
        XCTAssertEqual(command.expectedRevision, 7)
        XCTAssertTrue(try json(command)["targetDate"] is NSNull)
    }

    func testNaturalDateValidationAndTerminalTransitions() {
        XCTAssertTrue(GoalDraft.isNaturalDate("2028-02-29"))
        XCTAssertFalse(GoalDraft.isNaturalDate("2027-02-29"))
        XCTAssertFalse(GoalDraft.isNaturalDate("2026-2-03"))
        XCTAssertEqual(GoalTaskStatus.completed.nextStatuses, [.todo])
        XCTAssertEqual(GoalTaskStatus.canceled.nextStatuses, [.todo])
        let blocked = GoalDraft(id: "status", kind: .taskStatus, goalID: "goal-1", taskID: "task-1",
            expectedRevision: 1, status: .blocked, note: " \n ")
        XCTAssertFalse(blocked.isValid)
    }

    func testGoalsReadEveryPageWithFrozenQueryAndCursor() async throws {
        URLProtocolStubRegistry.shared.setHandler { request in
            if request.stubQueryValue("after") == "0" {
                return .json(200, "{\"goals\":[\(GoalWire.goal)],\"nextCursor\":1}")
            }
            return .json(200, "{\"goals\":[\(GoalWire.goal.replacingOccurrences(of: "goal-1", with: "goal-2"))],\"nextCursor\":null}")
        }
        let goals = try await makeStubAPI().goals(Fixtures.session(), status: .active)
        XCTAssertEqual(goals.map(\.id), ["goal-1", "goal-2"])
        let requests = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(requests.map { $0.stubQueryValue("after") }, ["0", "1"])
        XCTAssertTrue(requests.allSatisfy { $0.stubQueryValue("limit") == "100" && $0.stubQueryValue("status") == "active" })
    }

    func testProgressReadsAllPagesUsingFirstRevision() async throws {
        URLProtocolStubRegistry.shared.setHandler { request in
            let first = request.stubQueryValue("progressAfter") == "0"
            return .json(200, GoalWire.taskPage(entryID: first ? "entry-1" : "entry-2", next: first ? "1" : "null"))
        }
        let detail = try await makeStubAPI().goalTask(Fixtures.session(), taskID: "task-1")
        XCTAssertEqual(detail.progressEntries.map(\.id), ["entry-1", "entry-2"])
        XCTAssertNil(detail.nextCursor)
        let requests = URLProtocolStubRegistry.shared.requests
        XCTAssertEqual(requests.map { $0.stubQueryValue("progressAfter") }, ["0", "1"])
        XCTAssertNil(requests.first?.stubQueryValue("progressRevision"))
        XCTAssertEqual(requests.last?.stubQueryValue("progressRevision"), "2")
    }

    func testProgressRevisionConflictIsNotMergedOrRetried() async throws {
        URLProtocolStubRegistry.shared.setHandler { request in
            if request.stubQueryValue("progressAfter") == "0" { return .json(200, GoalWire.taskPage(entryID: "entry-1", next: "1")) }
            return .json(409, #"{"error":{"code":"progress_revision_conflict","message":"history changed"}}"#)
        }
        do {
            _ = try await makeStubAPI().goalTask(Fixtures.session(), taskID: "task-1")
            XCTFail("mixed revisions must fail")
        } catch let error as POSAPIError {
            guard case .conflict = error else { return XCTFail("expected conflict") }
        }
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.count, 2)
    }

    func testGoalQuestionUsesDedicatedRouteAndFixedRequestBody() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in
            .json(201, "{\"message\":\(Fixtures.message(text: "还剩什么")),\"run\":{\"id\":\"run-1\",\"conversationId\":\"conv-1\",\"messageId\":\"m1\",\"status\":\"queued\",\"goalId\":\"goal-1\"},\"created\":true}")
        }
        let request = GoalQuestionRequest(conversationID: "conv-1", clientRequestID: "req-1", text: "还剩什么")
        let ack = try await makeStubAPI().askGoal(Fixtures.session(), goalID: "goal-1", request)
        XCTAssertEqual(ack.run.goalId, "goal-1")
        let http = try XCTUnwrap(URLProtocolStubRegistry.shared.requests.first)
        XCTAssertEqual(http.stubPath, "/v2/goals/goal-1/questions")
        let body = try XCTUnwrap(http.stubBody)
        XCTAssertEqual(try JSONDecoder().decode(GoalQuestionRequest.self, from: body), request)
        XCTAssertEqual(http.value(forHTTPHeaderField: "authorization"), "Bearer test-token")
    }

    func testGoalContextDecodesFrozenOmissionsAndAcceptsOrdinaryNull() async throws {
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, "{\"goalContext\":\(GoalWire.context)}") }
        let fetched = try await makeStubAPI().goalContext(Fixtures.session(), runID: "run-1")
        let context = try XCTUnwrap(fetched)
        XCTAssertEqual(context.goal.title, "真实目标")
        XCTAssertEqual(context.summary.todoTasks, 1)
        XCTAssertEqual(context.omissions.progressEntryCount, 2)
        XCTAssertEqual(context.omissions.truncatedFields, ["goal.description"])
        XCTAssertEqual(URLProtocolStubRegistry.shared.requests.first?.stubPath, "/v2/runs/run-1/goal-context")
        URLProtocolStubRegistry.shared.setHandler { _ in .json(200, #"{"goalContext":null}"#) }
        let ordinary = try await makeStubAPI().goalContext(Fixtures.session(), runID: "run-2")
        XCTAssertNil(ordinary)
    }

    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

private enum GoalWire {
    static let goal = #"{"id":"goal-1","ownerId":"default","title":"真实目标","description":null,"successCriteria":null,"targetDate":null,"status":"active","archivedFromStatus":null,"revision":1,"createdAt":"2026-11-26T00:00:00Z","updatedAt":"2026-11-26T00:00:00Z"}"#
    static let task = #"{"id":"task-1","goalId":"goal-1","ownerId":"default","title":"真实任务","description":null,"dueDate":null,"status":"todo","blockedReason":null,"resultNote":null,"revision":2,"createdAt":"2026-11-26T00:00:00Z","updatedAt":"2026-11-26T00:00:00Z"}"#
    static let summary = #"{"completedTasks":0,"todoTasks":1,"inProgressTasks":0,"activeTasks":1,"blockedTasks":0,"canceledTasks":0,"completionPercent":0,"latestUpdatedAt":"2026-11-26T00:00:00Z"}"#
    static var context: String {
        "{\"runId\":\"run-1\",\"goalId\":\"goal-1\",\"goal\":\(goal),\"viewRevision\":2,\"asOf\":\"2026-11-26T00:00:00Z\",\"summary\":\(summary),\"includedTasks\":[{\"task\":\(task),\"progressEntries\":[]}],\"omissions\":{\"taskCount\":0,\"progressEntryCount\":2,\"truncatedFields\":[\"goal.description\"],\"reasons\":[\"text_truncated\"]}}"
    }
    static func taskPage(entryID: String, next: String) -> String {
        "{\"task\":\(task),\"progressEntries\":[{\"id\":\"\(entryID)\",\"taskId\":\"task-1\",\"actorDeviceId\":\"device-1\",\"kind\":\"note\",\"note\":\"进展\",\"fromStatus\":null,\"toStatus\":null,\"createdAt\":\"2026-11-26T00:00:00Z\"}],\"nextCursor\":\(next),\"progressRevision\":2}"
    }
}
