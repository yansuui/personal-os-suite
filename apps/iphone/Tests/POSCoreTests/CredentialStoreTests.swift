import XCTest
import POSCore

/// CredentialStore 协议语义：用内存替身验证读写/清除/幂等与可注入性，
/// 不触碰真实 Keychain（真实实现只在真机/模拟器运行时使用）。
final class CredentialStoreTests: XCTestCase {
    func testLoadReturnsNilWhenEmpty() throws {
        let store = MemoryCredentialStore()

        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTripsSession() throws {
        let store = MemoryCredentialStore()
        let session = try Fixtures.session(token: "token-abc")

        try store.save(session)

        XCTAssertEqual(try store.load(), session)
        XCTAssertEqual(try store.load()?.token, "token-abc")
        XCTAssertEqual(try store.load()?.device.id, "device-1")
    }

    func testSaveOverwritesPreviousSession() throws {
        let store = MemoryCredentialStore()
        try store.save(try Fixtures.session(token: "first"))
        let second = try Fixtures.session(token: "second")

        try store.save(second)

        XCTAssertEqual(try store.load(), second)
    }

    func testClearIsIdempotent() throws {
        let store = MemoryCredentialStore()
        try store.save(try Fixtures.session())

        try store.clear()
        XCTAssertNil(try store.load())

        // 再清一次不抛错（Keychain 实现在 errSecItemNotFound 时同样当成功）。
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertEqual(store.clearCount, 2)
    }

    func testStoreIsInjectableAsProtocolExistential() throws {
        // C 的 AppModel 以 CredentialStore 注入，这里验证替身可经协议使用。
        let store: CredentialStore = MemoryCredentialStore()
        let session = try Fixtures.session()

        try store.save(session)

        XCTAssertEqual(try store.load(), session)
    }

    func testKeychainStoreCanBeConstructedWithDefaultService() {
        // 只验证公开初始化的默认值存在；真正的 Keychain 读写由 CI 之外的运行环境覆盖。
        let store = KeychainCredentialStore()
        let custom = KeychainCredentialStore(service: "com.example.custom")

        XCTAssertNotNil(store as CredentialStore)
        XCTAssertNotNil(custom as CredentialStore)
    }
}
