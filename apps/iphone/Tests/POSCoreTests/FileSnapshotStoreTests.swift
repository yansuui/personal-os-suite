import XCTest
import POSCore

/// FileSnapshotStore：目录内 JSON 原子写、缺失返回 nil、重复保存覆盖；
/// CachedSnapshot 的 Codable 往返（含 ContextSnapshot 扁平字段）。
final class FileSnapshotStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("POSCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    func testLoadSnapshotReturnsNilWhenFileMissing() throws {
        let store = FileSnapshotStore(directory: directory)

        XCTAssertNil(try store.loadSnapshot())
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = FileSnapshotStore(directory: directory)
        let snapshot = CachedSnapshot(
            savedAt: "2026-01-01T00:00:00.000Z",
            timeline: [],
            cursor: 7,
            tasks: [],
            context: nil
        )

        try store.saveSnapshot(snapshot)

        XCTAssertEqual(try store.loadSnapshot(), snapshot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("snapshot.json").path
        ))
    }

    func testSaveOverwritesPreviousSnapshot() throws {
        let store = FileSnapshotStore(directory: directory)
        try store.saveSnapshot(CachedSnapshot(savedAt: "a", timeline: [], cursor: 1, tasks: [], context: nil))
        let newer = CachedSnapshot(savedAt: "b", timeline: [], cursor: 2, tasks: [], context: nil)

        try store.saveSnapshot(newer)

        XCTAssertEqual(try store.loadSnapshot(), newer)
    }

    func testContextSnapshotRoundTripsThroughCacheEncoding() throws {
        // 先按服务端 /v1/context 形状解码，再经缓存编码/解码回到相同的扁平值。
        let snapshot = try Fixtures.decode(ContextSnapshot.self, from: """
        {
          "snapshots": [
            {
              "kind": "plan",
              "asOf": "2026-01-02T00:00:00.000Z",
              "payload": {
                "available": true,
                "items": [
                  {
                    "id": "plan-1",
                    "planDate": "2026-01-02",
                    "title": "写代码",
                    "owner": "ai",
                    "startTime": null,
                    "endTime": null,
                    "minutes": 30,
                    "status": "done",
                    "progress": 100
                  }
                ]
              }
            }
          ]
        }
        """)
        XCTAssertTrue(snapshot.available)
        XCTAssertEqual(snapshot.plan.first?.owner, "ai")

        let store = FileSnapshotStore(directory: directory)
        try store.saveSnapshot(CachedSnapshot(
            savedAt: "2026-01-02T00:00:00.000Z",
            timeline: [],
            cursor: 0,
            tasks: [],
            context: snapshot
        ))

        let restored = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(restored.context, snapshot)
    }

    func testEmptySnapshotsPayloadMeansUnavailable() throws {
        let snapshot = try Fixtures.decode(ContextSnapshot.self, from: #"{"snapshots":[]}"#)

        XCTAssertFalse(snapshot.available)
        XCTAssertTrue(snapshot.plan.isEmpty)
        XCTAssertTrue(snapshot.memory.isEmpty)
        XCTAssertNil(snapshot.asOf)
    }
}
