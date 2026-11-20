import Foundation
import SwiftUI
import POSCore

/// 记忆：只读列表 + 本地搜索过滤。数据来自 `/v1/context` 的云端快照。
struct MemoryView: View {
    @ObservedObject var model: AppModel
    @State private var query: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
                SearchField(placeholder: "搜索记忆内容、标签或来源", text: $query)

                if let notice = model.notice {
                    ErrorBanner(
                        message: notice,
                        tint: POSTheme.warning,
                        onDismiss: { model.dismissNotice() }
                    )
                }

                content
            }
            .padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("记忆")
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            RefreshToolbar(isRefreshing: model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
    }

    // MARK: - 数据

    private var allHits: [MemoryHit] {
        (model.context?.memory ?? []).sorted(by: POSCoreBridge.memoryOrder)
    }

    private var filteredHits: [MemoryHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return allHits }
        return allHits.filter { hit in
            if hit.content.lowercased().contains(needle) { return true }
            if hit.kind.lowercased().contains(needle) { return true }
            if hit.scope.lowercased().contains(needle) { return true }
            return hit.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    // MARK: - 视图

    @ViewBuilder
    private var content: some View {
        if allHits.isEmpty {
            if model.isRefreshing {
                LoadingStateView(title: "正在同步记忆…")
            } else {
                EmptyStateView(
                    title: "还没有记忆",
                    message: "记忆由云端提供，桌面端同步后会出现在这里。",
                    systemImage: "brain",
                    actionTitle: "刷新",
                    action: { Task { await model.refresh() } }
                )
            }
        } else if filteredHits.isEmpty {
            EmptyStateView(
                title: "没有匹配的记忆",
                message: "换个关键词试试。",
                systemImage: "magnifyingglass"
            )
        } else {
            ForEach(filteredHits) { hit in
                MemoryCard(hit: hit)
            }
        }
    }
}

/// 记忆卡片：内容、标签、kind、scope、重要性、更新时间。
struct MemoryCard: View {
    let hit: MemoryHit

    var body: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
            Text(hit.content)
                .font(.subheadline)
                .foregroundStyle(POSTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !hit.tags.isEmpty {
                Text(hit.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(POSTheme.info)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: POSTheme.Spacing.xs) {
                StatusPill(text: hit.kind, tint: POSTheme.info)
                StatusPill(text: scopeTitle(hit.scope), tint: POSTheme.secondaryText)
                StatusPill(
                    text: "重要性 \(hit.importance)",
                    tint: hit.importance >= 3 ? POSTheme.warning : POSTheme.secondaryText
                )
            }

            Text("更新于 \(POSDate.relative(hit.updatedAt))")
                .font(.caption2)
                .foregroundStyle(POSTheme.tertiaryText)
        }
        .posCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("记忆：\(hit.content)，类别 \(hit.kind)，重要性 \(hit.importance)"))
    }

    private func scopeTitle(_ scope: String) -> String {
        switch scope {
        case "user":
            return "全局"
        case "workspace":
            return "工作区"
        case "project":
            return "项目"
        default:
            return scope
        }
    }
}
