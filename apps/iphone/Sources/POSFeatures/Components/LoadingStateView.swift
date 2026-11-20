import SwiftUI

/// 进行中/加载态：转圈 + 一行说明。
struct LoadingStateView: View {
    var title: String = "正在同步…"

    var body: some View {
        HStack(spacing: POSTheme.Spacing.s) {
            ProgressView()
            Text(title)
                .font(.subheadline)
                .foregroundStyle(POSTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(POSTheme.Spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}
