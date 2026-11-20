import SwiftUI

/// 连接状态横幅：在线/离线 + 最后同步时间 + 离线时的重连入口。
struct ConnectionBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let online = model.connection.isOnline
        let tint = online ? POSTheme.success : POSTheme.warning

        VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
            HStack(spacing: POSTheme.Spacing.s) {
                StatusPill(
                    text: online ? "在线" : "离线",
                    tint: tint,
                    systemImage: online ? "wifi" : "wifi.slash"
                )

                Text("最后同步 \(POSDate.relative(model.lastSyncedAt))")
                    .font(.caption)
                    .foregroundStyle(POSTheme.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if !online {
                    Button {
                        Task { await model.reconnect() }
                    } label: {
                        Text("重连")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(POSTheme.accent)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("重新连接服务器"))
                }
            }

            if let reason = model.connection.offlineReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(POSTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, POSTheme.Spacing.l)
        .padding(.vertical, POSTheme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
