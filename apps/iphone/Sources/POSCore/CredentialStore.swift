import Foundation
import Security

/// 设备会话的持久化。UI/AppModel 只依赖本协议，测试可注入内存替身。
///
/// CONTRACT §3 公开面，签名不可改。
public protocol CredentialStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

/// Keychain 实现：Generic Password，service 默认 `com.personalos.ios.session`，
/// account 固定 `session`，可访问性 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
///
/// 抛出的错误只带 OSStatus 与固定文案，**绝不包含 token 正文**（CONTRACT §3 行为 6）。
public struct KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String
    private static let account = "session"

    public init(service: String = "com.personalos.ios.session") {
        self.service = service
    }

    public func load() throws -> AuthSession? {
        var query: [String: Any] = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.status(status, operation: "读取会话")
        }
        guard let data = item as? Data else {
            throw KeychainError.message("读取会话失败：Keychain 返回了非二进制数据")
        }
        do {
            return try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            // 不拼接底层错误（其中可能带解码失败的值片段）。
            throw KeychainError.message("读取会话失败：保存的数据无法解析")
        }
    }

    public func save(_ session: AuthSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw KeychainError.message("保存会话失败：会话无法序列化")
        }

        // 先删后写：同一 service + account 只保留一份，重复保存是幂等的。
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw KeychainError.status(deleteStatus, operation: "清理旧会话")
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.status(addStatus, operation: "保存会话")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        // 没有数据也算成功（幂等）。
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.status(status, operation: "清理会话")
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }
}

/// Keychain 错误：只保留操作名与 OSStatus，不含任何凭据内容。
struct KeychainError: Error, CustomStringConvertible {
    let operation: String
    let osStatus: OSStatus?
    let text: String?

    static func status(_ status: OSStatus, operation: String) -> KeychainError {
        KeychainError(operation: operation, osStatus: status, text: nil)
    }

    static func message(_ text: String) -> KeychainError {
        KeychainError(operation: "", osStatus: nil, text: text)
    }

    var description: String {
        if let text { return text }
        if let osStatus { return "\(operation)失败（OSStatus \(osStatus)）" }
        return "\(operation)失败"
    }
}
