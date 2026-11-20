import SwiftUI

/// 错误/提示横幅。支持标题、说明、重试和关闭。
struct ErrorBanner: View {
    let message: String
    var title: String? = nil
    var tint: Color = POSTheme.danger
    var retryTitle: String? = nil
    var onRetry: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: POSTheme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(POSTheme.primaryText)
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(POSTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let retryTitle, let onRetry {
                    Button(retryTitle, action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint)
                        .accessibilityLabel(Text(retryTitle))
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(POSTheme.secondaryText)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭提示"))
            }
        }
        .padding(POSTheme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
