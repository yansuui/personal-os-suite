import Foundation

/// 网络层错误的统一映射。
///
/// CONTRACT §3 公开面，签名不可改。
/// 约束：所有 case 的正文都不得包含设备 token（见 URLSessionPOSAPI 的实现注释）。
public enum POSAPIError: Error, Sendable, Equatable {
    /// 网络不可达 / 超时。
    case transport(String)
    /// 401 / 403：token 失效或角色不足。
    case unauthorized
    /// 409：版本/幂等冲突。调用方必须刷新，不得自动覆盖。
    case conflict(String)
    /// 其它非 2xx；code/message 来自服务端 `{ error: { code, message } }`。
    case server(status: Int, code: String, message: String)
    /// 响应不是预期 JSON 结构。
    case decoding(String)
}
