import SwiftUI
import POSCore

/// 消息气泡：用户靠右、助手靠左、系统居中。
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == "user" {
            userBubble
        } else if message.role == "system" {
            systemRow
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: POSTheme.Spacing.xxl)
            VStack(alignment: .trailing, spacing: POSTheme.Spacing.xxs) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, POSTheme.Spacing.m)
                    .padding(.vertical, POSTheme.Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                            .fill(POSTheme.accent)
                    )

                Text(POSDate.shortStamp(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(POSTheme.tertiaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("我：\(message.text)"))
        }
    }

    private var assistantBubble: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(POSTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, POSTheme.Spacing.m)
                    .padding(.vertical, POSTheme.Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                            .fill(POSTheme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: POSTheme.Radius.card, style: .continuous)
                            .strokeBorder(POSTheme.stroke.opacity(0.5), lineWidth: 1)
                    )

                Text(POSDate.shortStamp(message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(POSTheme.tertiaryText)
            }
            Spacer(minLength: POSTheme.Spacing.xxl)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("助手：\(message.text)"))
    }

    private var systemRow: some View {
        Text(message.text)
            .font(.caption)
            .foregroundStyle(POSTheme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, POSTheme.Spacing.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("系统提示：\(message.text)"))
    }
}
