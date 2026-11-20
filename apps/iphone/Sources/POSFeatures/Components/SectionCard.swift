import SwiftUI

/// 卡片区块：标题行 + 内容，视觉与 TaskCard 一致。
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var caption: String? = nil
    let content: Content

    init(title: String,
         systemImage: String? = nil,
         caption: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
            HStack(spacing: POSTheme.Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(POSTheme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(POSTheme.primaryText)
                Spacer(minLength: 0)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(POSTheme.secondaryText)
                }
            }
            content
        }
        .posCard()
        .accessibilityElement(children: .contain)
    }
}

/// 我的页用的「标签 - 值」行。
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: POSTheme.Spacing.s) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(POSTheme.secondaryText)
                .frame(minWidth: 84, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(POSTheme.primaryText)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label)：\(value)"))
    }
}
