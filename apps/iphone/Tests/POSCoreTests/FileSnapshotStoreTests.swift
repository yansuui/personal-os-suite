import XCTest
import POSCore

final class FileSnapshotStoreTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("POSCoreTests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        super.tearDown()
    }

    func testMissingFileReturnsNil() throws {
        XCTAssertNil(try FileSnapshotStore(directory: directory).loadSnapshot())
    }

    func testV2SnapshotRestoresConversationCursorAndPendingIdempotencyKey() throws {
        let conversation = try Fixtures.decode(Conversation.self, from: Fixtures.conversationJSON)
        let message = try Fixtures.decode(ChatMessage.self, from: Fixtures.message())
        let pending = PendingMessage(conversationID: conversation.id, clientRequestID: "persistent-key", text: "offline", createdAt: "now")
        let snapshot = CachedSnapshot(savedAt: "2026-01-01T00:00:00Z", conversations: [conversation],
            selectedConversationID: conversation.id,
            conversationStates: [ConversationSnapshot(conversationID: conversation.id, messages: [message], cursor: 1)],
            pendingMessages: [pending])
        let store = FileSnapshotStore(directory: directory)
        try store.saveSnapshot(snapshot)
        let restored = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.pendingMessages[0].request.clientRequestID, "persistent-key")
        XCTAssertEqual(restored.conversationStates[0].cursor, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.json").path))
    }

    func testLegacySnapshotRemainsReadableWithoutInventingV2Conversation() throws {
        let old = try Fixtures.decode(CachedSnapshot.self, from: #"{"savedAt":"2026-01-01T00:00:00Z","timeline":[{"id":"old","seq":7,"role":"user","text":"saved","createdAt":"now"}],"cursor":7,"tasks":[],"context":{"available":false,"plan":[],"memory":[],"asOf":null}}"#)
        XCTAssertEqual(old.timeline.first?.text, "saved")
        XCTAssertEqual(old.cursor, 7)
        XCTAssertNil(old.timeline.first?.conversationID)
        XCTAssertNil(old.selectedConversationID)
        XCTAssertTrue(old.conversationStates.isEmpty)
        XCTAssertTrue(old.pendingMessages.isEmpty)
        let store = FileSnapshotStore(directory: directory)
        try store.saveSnapshot(old)
        XCTAssertEqual(try store.loadSnapshot(), old)
    }

    func testSaveOverwritesSnapshotAtomically() throws {
        let store = FileSnapshotStore(directory: directory)
        try store.saveSnapshot(CachedSnapshot(savedAt: "a"))
        let next = CachedSnapshot(savedAt: "b")
        try store.saveSnapshot(next)
        XCTAssertEqual(try store.loadSnapshot(), next)
    }
}
