import SwiftUI

/// 统一的操作按钮：文字 + 可选图标，内部处理禁用态与进行中态。
struct ActionButton: View {
    let title: String
    var systemImage: String? = nil
    var variant: POSButtonStyle.Variant = .secondary
    var isBusy: Bool = false
    var accessibility: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: POSTheme.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .buttonStyle(POSButtonStyle(variant: variant, isBusy: isBusy))
        .disabled(isBusy)
        .accessibilityLabel(Text(accessibility ?? title))
    }
}
