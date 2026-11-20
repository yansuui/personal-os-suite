import Foundation

/// 服务端基础地址。
///
/// CONTRACT §3 公开面，签名不可改。
public struct ServerConfig: Sendable, Equatable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
}
