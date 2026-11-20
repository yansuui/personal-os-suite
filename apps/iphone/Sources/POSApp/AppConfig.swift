import Foundation

/// App 级配置（CONTRACT §5）。
///
/// 服务器地址来源：Info.plist 的 `POSServerURL`，其值由 xcconfig 的 `POS_SERVER_URL`
/// 在构建时注入（见 Config/Debug.xcconfig、Staging.xcconfig、Release.xcconfig）。
/// 缺失或非法时回落到 `http://127.0.0.1:3080`（契约里的 Debug 默认地址）。
enum AppConfig {

    /// Info.plist 中的键名。
    static let serverURLInfoKey = "POSServerURL"

    /// 回落地址（CONTRACT §5）。
    static let fallbackServerURLString = "http://127.0.0.1:3080"

    /// 进程内只解析一次；首次访问时按 `#if DEBUG` 打印一次来源。
    static let serverURL: URL = resolveServerURL()

    /// 常量字符串对应的 URL；常量不可能非法，保留断言只为尽早暴露笔误。
    static let fallbackServerURL: URL = {
        guard let url = URL(string: fallbackServerURLString) else {
            assertionFailure("回落地址常量非法: \(fallbackServerURLString)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }()

    // MARK: - 解析

    private static func resolveServerURL() -> URL {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: serverURLInfoKey)
        let text = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let url = validatedServerURL(from: text) {
            #if DEBUG
            print("[AppConfig] serverURL = \(url.absoluteString)（来源：Info.plist.\(serverURLInfoKey)）")
            #else
            if url.scheme?.lowercased() == "http" {
                print("[AppConfig] 警告：非 Debug 构建使用明文地址 \(url.absoluteString)，ATS 只放开了本地网络")
            }
            #endif
            return url
        }

        #if DEBUG
        if text.isEmpty {
            print("[AppConfig] Info.plist.\(serverURLInfoKey) 缺失，回落默认地址 \(fallbackServerURL.absoluteString)")
        } else {
            print("[AppConfig] Info.plist.\(serverURLInfoKey) = \"\(text)\" 非法，回落默认地址 \(fallbackServerURL.absoluteString)")
        }
        #else
        print("[AppConfig] 服务器地址缺失或非法，使用默认地址 \(fallbackServerURL.absoluteString)")
        #endif
        return fallbackServerURL
    }

    /// 只接受 http/https 且带非空 host 的绝对 URL。
    /// 未展开的占位符（形如 `$(POS_SERVER_URL)`）直接判非法，避免把构建变量当主机名用。
    private static func validatedServerURL(from text: String) -> URL? {
        guard !text.isEmpty, !text.contains("$(") else { return nil }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
