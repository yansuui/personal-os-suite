import SwiftUI

/// 空态：图标 + 标题 + 可选说明 + 可选操作。
/// 文案全部走语义字体，支持动态字体放大，不写死行高。
struct EmptyStateView: View {
    let title: String
    var message: String? = nil
    var systemImage: String = "tray"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: POSTheme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(POSTheme.secondaryText)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .foregroundStyle(POSTheme.primaryText)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(POSTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(POSButtonStyle(variant: .secondary))
                    .fixedSize()
                    .accessibilityLabel(Text(actionTitle))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, POSTheme.Spacing.l)
        .padding(.vertical, POSTheme.Spacing.xl)
        .accessibilityElement(children: .contain)
    }
}
