import SwiftUI

import POSCore
import POSFeatures

/// 应用入口（CONTRACT §5）。
///
/// `AppModel` / `RootView` 来自 POSFeatures；网络实现由这里注入。
/// 传工厂而不是实例：配对页允许改服务器地址，AppModel 需要按新地址重建客户端。
@main
struct POSApp: App {
    @StateObject private var model: AppModel

    init() {
        let url = AppConfig.serverURL
        _model = StateObject(wrappedValue: AppModel(
            serverURL: url,
            apiFactory: { address in
                URLSessionPOSAPI(config: ServerConfig(baseURL: address))
            }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
