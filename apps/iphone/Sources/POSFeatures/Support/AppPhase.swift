import Foundation

/// 应用主阶段。
///
/// CONTRACT-GAP：CONTRACT §4 在 `AppModel.phase` 的类型标注里引用了 `AppPhase`，
/// 但 §3/§4 均未给出它的定义。这里按任务书要求实现
/// `.signedOut` → `.pairing` → `.ready` / `.failed(String)`。
/// 若后续把 `AppPhase` 移入 POSCore，本文件删除即可，页面与 AppModel 的用法不变。
public enum AppPhase: Equatable, Sendable {
    /// 未配对（无会话）。
    case signedOut
    /// 正在配对。
    case pairing
    /// 已配对且可用。
    case ready
    /// 配对/鉴权失败，附带可展示的原因。
    case failed(String)

    /// 失败原因（仅 `.failed` 有值）。
    public var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }

    /// 是否已经可用。
    public var isReady: Bool {
        self == .ready
    }

    /// 是否处于配对中（用于按钮进行中态）。
    public var isPairing: Bool {
        self == .pairing
    }

    /// 我的页「配对状态」文案。
    public var displayName: String {
        switch self {
        case .signedOut:
            return "未配对"
        case .pairing:
            return "配对中"
        case .ready:
            return "已配对"
        case .failed:
            return "配对失败"
        }
    }
}

/// 与服务器的连接状态（契约外用状态，仅用于界面横幅）。
public enum ConnectionState: Equatable, Sendable {
    /// 尚未建立过连接。
    case unknown
    /// 在线（最近一次同步/事件成功）。
    case online
    /// 离线，附带可展示的原因。
    case offline(String)

    public var isOnline: Bool {
        if case .online = self {
            return true
        }
        return false
    }

    public var offlineReason: String? {
        if case .offline(let reason) = self {
            return reason
        }
        return nil
    }
}
