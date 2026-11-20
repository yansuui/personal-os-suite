import Foundation

/// 本地快照存储（离线首屏 + 游标）。
///
/// CONTRACT §3 公开面，签名不可改。
public protocol SnapshotStore: Sendable {
    func loadSnapshot() throws -> CachedSnapshot?
    func saveSnapshot(_ snapshot: CachedSnapshot) throws
}

/// 默认实现：Application Support 下的 JSON 文件，原子写。
///
/// CONTRACT-DEVIATION: CONTRACT §3 的 `FileSnapshotStore.init(directory:)` 只接收目录，
/// 没有 `baseURL` / 设备 id 入参，本类型无法在内部按「host + 设备 id」哈希命名。
/// 因此把「服务器 + 设备」维度交给调用方：传入的目录即一个身份范围，目录内固定写
/// `snapshot.json`（不同目录互不覆盖）；默认目录为
/// `Application Support/com.personalos.ios/snapshots`。
public struct FileSnapshotStore: SnapshotStore, Sendable {
    private static let fileName = "snapshot.json"

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    public func loadSnapshot() throws -> CachedSnapshot? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CachedSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: CachedSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let data = try JSONEncoder().encode(snapshot)
        // .atomic：先写临时文件再替换，进程中断不会留下半个 JSON。
        try data.write(to: fileURL, options: [.atomic])
    }

    private var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("com.personalos.ios", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
    }
}
