import SwiftUI

/// 导航栏右侧刷新按钮，统一进行中态：刷新时换成转圈并禁用。
struct RefreshToolbar: ToolbarContent {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: action) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)
            .accessibilityLabel(Text(isRefreshing ? "正在刷新" : "刷新"))
        }
    }
}
