import Foundation
import SwiftUI

/// 我的：服务器地址、设备名、配对状态、最后同步时间、重新配对入口、退出登录。
struct MeView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                profileCard
                connectionCard
                SectionCard(title: "当前能力", systemImage: "info.circle") {
                    Text("v2 已接入会话和消息同步。任务、审批、计划、记忆和设备在线状态尚未接入。")
                        .font(.footnote)
                }
                pairingEntry
                signOutSection
            }
            .padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("我的")
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            RefreshToolbar(isRefreshing: model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
        .alert("退出登录？", isPresented: $confirmingSignOut) {
            Button("退出登录", role: .destructive) {
                model.signOut()
            }
            Button("取消", role: .cancel) {
            }
        } message: {
            Text("将清除本机保存的配对凭据；会话与消息的离线缓存保留在本机。")
        }
    }

    // MARK: - 头部

    private var profileCard: some View {
        HStack(spacing: POSTheme.Spacing.m) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(.largeTitle))
                .foregroundStyle(POSTheme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
                Text(model.deviceName.isEmpty ? "未命名设备" : model.deviceName)
                    .font(.headline)
                    .foregroundStyle(POSTheme.primaryText)
                Text(model.phase.displayName)
                    .font(.caption)
                    .foregroundStyle(POSTheme.secondaryText)
            }

            Spacer(minLength: 0)

            StatusPill(
                text: model.connection.isOnline ? "在线" : "离线",
                tint: model.connection.isOnline ? POSTheme.success : POSTheme.warning
            )
        }
        .posCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(model.deviceName.isEmpty ? "未命名设备" : model.deviceName)，\(model.phase.displayName)")
        )
    }

    // MARK: - 连接信息

    private var connectionCard: some View {
        SectionCard(title: "连接", systemImage: "network") {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                InfoRow(label: "服务器地址", value: model.serverURL.absoluteString)
                InfoRow(label: "模型", value: model.modelDisplayName)
                InfoRow(label: "设备名", value: model.deviceName.isEmpty ? "未配对" : model.deviceName)
                InfoRow(label: "配对状态", value: model.phase.displayName)
                InfoRow(label: "最后同步", value: POSDate.relative(model.lastSyncedAt))
            }
        }
    }

    // MARK: - 配对入口

    private var pairingEntry: some View {
        NavigationLink {
            PairingView(model: model)
        } label: {
            HStack(spacing: POSTheme.Spacing.s) {
                Image(systemName: "link")
                    .foregroundStyle(POSTheme.accent)
                    .accessibilityHidden(true)
                Text(model.session == nil ? "配对设备" : "重新配对")
                    .font(.subheadline)
                    .foregroundStyle(POSTheme.primaryText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(POSTheme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .posCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.session == nil ? "配对设备" : "重新配对"))
    }

    // MARK: - 退出

    private var signOutSection: some View {
        VStack(spacing: POSTheme.Spacing.s) {
            ActionButton(
                title: "退出登录",
                systemImage: "rectangle.portrait.and.arrow.right",
                variant: .destructive,
                accessibility: "退出登录"
            ) {
                confirmingSignOut = true
            }

            Text("退出后需要重新配对才能继续同步。")
                .font(.footnote)
                .foregroundStyle(POSTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
