import SwiftUI

/// 本地过滤用的搜索框（不做网络请求）。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: POSTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(POSTheme.secondaryText)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(Text(placeholder))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(POSTheme.tertiaryText)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("清除搜索内容"))
            }
        }
        .padding(.horizontal, POSTheme.Spacing.m)
        .padding(.vertical, POSTheme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous)
                .fill(POSTheme.cardAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: POSTheme.Radius.control, style: .continuous)
                .strokeBorder(POSTheme.stroke, lineWidth: 1)
        )
    }
}
