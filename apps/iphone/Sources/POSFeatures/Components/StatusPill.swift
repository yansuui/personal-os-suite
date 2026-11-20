import SwiftUI

/// 状态胶囊：所有「状态」类文案统一用它，颜色由调用方给定。
struct StatusPill: View {
    let text: String
    var tint: Color = POSTheme.info
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: POSTheme.Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, POSTheme.Spacing.s)
        .padding(.vertical, POSTheme.Spacing.xxs + 2)
        .foregroundStyle(tint)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.15))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}
