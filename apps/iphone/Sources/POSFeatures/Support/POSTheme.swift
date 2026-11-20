import SwiftUI
import UIKit

/// 设计令牌：颜色 / 间距 / 圆角。
///
/// 颜色一律取系统动态色，因此深色模式自动适配，不在各页面里硬编码 RGB。
/// 这里只做取色与尺寸常量，不引入 UIKit 视图。
enum POSTheme {

    // MARK: - 颜色

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardAlt = Color(uiColor: .tertiarySystemGroupedBackground)
    static let stroke = Color(uiColor: .separator)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let accent = Color.accentColor
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let info = Color(uiColor: .systemBlue)

    // MARK: - 间距

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - 圆角

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 10
        static let pill: CGFloat = 999
    }
}

// MARK: - 卡片容器

extension View {
    /// 统一卡片外观：内边距 + 底色 + 细描边。
    func posCard(padding: CGFloat = POSTheme.Spacing.l) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                    .fill(POSTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                    .strokeBorder(POSTheme.stroke.opacity(0.6), lineWidth: 1)
            )
    }
}

// MARK: - 按钮样式

/// 统一的文字按钮样式，覆盖禁用态与进行中态（进行中显示转圈并压暗文字）。
struct POSButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case destructive
    }

    var variant: Variant = .primary
    var isBusy: Bool = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        POSButtonBody(configuration: configuration, variant: variant, isBusy: isBusy)
    }

    private struct POSButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        let isBusy: Bool

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: POSTheme.Spacing.xs) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(contentColor)
                }
                configuration.label
                    .opacity(isBusy ? 0.35 : 1)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(contentColor)
            .padding(.horizontal, POSTheme.Spacing.m)
            .padding(.vertical, POSTheme.Spacing.s)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var contentColor: Color {
            switch variant {
            case .primary:
                return isEnabled ? Color.white : POSTheme.tertiaryText
            case .secondary:
                return isEnabled ? POSTheme.primaryText : POSTheme.tertiaryText
            case .destructive:
                return isEnabled ? POSTheme.danger : POSTheme.tertiaryText
            }
        }

        private var fillColor: Color {
            switch variant {
            case .primary:
                return POSTheme.accent
            case .secondary:
                return POSTheme.cardAlt
            case .destructive:
                return POSTheme.danger.opacity(0.12)
            }
        }

        private var borderColor: Color {
            switch variant {
            case .primary:
                return POSTheme.accent
            case .secondary:
                return POSTheme.stroke
            case .destructive:
                return POSTheme.danger.opacity(0.4)
            }
        }
    }
}
