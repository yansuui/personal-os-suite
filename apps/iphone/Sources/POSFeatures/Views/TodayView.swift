import Foundation
import SwiftUI
import POSCore

/// 今日：今日计划、下一项、助手正在处理、待我决定、最近结果。
struct TodayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                if let notice = model.notice {
                    ErrorBanner(
                        message: notice,
                        title: "提示",
                        tint: POSTheme.warning,
                        onDismiss: { model.dismissNotice() }
                    )
                }

                if model.needsRefresh {
                    ErrorBanner(
                        message: "服务端数据已更新，本地内容可能过期。",
                        title: "需要刷新",
                        tint: POSTheme.warning,
                        retryTitle: "立即刷新",
                        onRetry: { Task { await model.refresh() } }
                    )
                }

                header

                if isLoading {
                    LoadingStateView(title: "正在同步今日安排…")
                } else if isCompletelyEmpty {
                    EmptyStateView(
                        title: "今天还没有内容",
                        message: "同步成功后，计划、任务和结果会出现在这里。",
                        systemImage: "sun.max",
                        actionTitle: "刷新",
                        action: { Task { await model.refresh() } }
                    )
                } else {
                    planSection
                    nextItemSection
                    assistantSection
                    decisionsSection
                    recentResultsSection
                }
            }
            .padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("今日")
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            RefreshToolbar(isRefreshing: model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
    }

    // MARK: - 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
            Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.subheadline)
                .foregroundStyle(POSTheme.secondaryText)

            Text(greetingTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(POSTheme.primaryText)

            if let presence = model.presence {
                Text(presenceSummary(presence))
                    .font(.footnote)
                    .foregroundStyle(POSTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var greetingTitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<9:
            return "早上好"
        case 9..<12:
            return "上午好"
        case 12..<18:
            return "下午好"
        default:
            return "晚上好"
        }
    }

    private func presenceSummary(_ presence: Presence) -> String {
        var parts: [String] = []
        parts.append(presence.desktopOnline ? "桌面在线" : "桌面离线")
        parts.append(presence.cloudAgentOnline ? "云端在线" : "云端离线")
        if presence.queuedChat > 0 {
            parts.append("\(presence.queuedChat) 条消息排队")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 数据切片

    private var todayKey: String {
        POSDate.dayKey()
    }

    private var isLoading: Bool {
        model.isRefreshing && model.context == nil && model.tasks.isEmpty
    }

    private var isCompletelyEmpty: Bool {
        model.context == nil && model.tasks.isEmpty && model.messages.isEmpty
    }

    /// 今日计划：按 `planDate` 过滤，按开始时间排序。
    private var todayPlan: [PlanItem] {
        (model.context?.plan ?? [])
            .filter { $0.planDate == todayKey }
            .sorted { lhs, rhs in
                let left = POSDate.minutesOfDay(from: lhs.startTime) ?? Int.max
                let right = POSDate.minutesOfDay(from: rhs.startTime) ?? Int.max
                if left != right {
                    return left < right
                }
                return lhs.title < rhs.title
            }
    }

    private var completedPlanCount: Int {
        todayPlan.filter { $0.status == "done" }.count
    }

    /// 下一项：当前时间之后最近的一条未完成项；没有则退回第一条未完成项。
    private var nextItem: PlanItem? {
        let now = POSDate.minutesSinceMidnight()
        let pending = todayPlan.filter { $0.status == "todo" }
        let upcoming = pending.first { item in
            let start = POSDate.minutesOfDay(from: item.startTime) ?? Int.max
            return start >= now
        }
        return upcoming ?? pending.first
    }

    private var activeTasks: [TaskSummary] {
        model.tasks
            .filter { $0.status == "running" || $0.status == "queued" }
            .sorted(by: POSCoreBridge.taskOrder)
    }

    /// 待我决定：需要审批（requiresApproval / waiting-approval）或待验收。
    private var decisions: [TaskSummary] {
        model.tasks
            .filter { $0.isAwaitingApproval || $0.isAwaitingVerdict }
            .sorted(by: POSCoreBridge.taskOrder)
    }

    private var recentResults: [TaskSummary] {
        Array(
            model.tasks
                .filter { $0.bucket == .finished || $0.bucket == .failed }
                .sorted(by: POSCoreBridge.taskOrder)
                .prefix(3)
        )
    }

    // MARK: - 今日计划

    @ViewBuilder
    private var planSection: some View {
        if todayPlan.isEmpty {
            SectionCard(title: "今日计划", systemImage: "calendar") {
                Text(planEmptyText)
                    .font(.subheadline)
                    .foregroundStyle(POSTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            SectionCard(
                title: "今日计划",
                systemImage: "calendar",
                caption: "\(completedPlanCount)/\(todayPlan.count) 已完成"
            ) {
                VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
                    ForEach(todayPlan) { item in
                        planRow(item)
                    }
                }
            }
        }
    }

    private var planEmptyText: String {
        guard let context = model.context else {
            return "还没有同步到计划。"
        }
        if !context.available {
            return "云端上下文暂不可用，计划稍后同步。"
        }
        return "今天没有安排，留点空白也很好。"
    }

    private func planRow(_ item: PlanItem) -> some View {
        HStack(alignment: .top, spacing: POSTheme.Spacing.s) {
            Image(systemName: item.status == "done" ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.status == "done" ? POSTheme.success : POSTheme.tertiaryText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(POSTheme.primaryText)
                    .strikethrough(item.status == "done", color: POSTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: POSTheme.Spacing.xs) {
                    if let start = item.startTime {
                        Text(timeRange(start: start, end: item.endTime))
                            .font(.caption)
                            .foregroundStyle(POSTheme.secondaryText)
                    }
                    if let minutes = item.minutes {
                        Text("\(minutes) 分钟")
                            .font(.caption)
                            .foregroundStyle(POSTheme.secondaryText)
                    }
                    if item.status == "skipped" {
                        Text("已跳过")
                            .font(.caption)
                            .foregroundStyle(POSTheme.secondaryText)
                    }
                }
            }

            Spacer(minLength: 0)

            StatusPill(
                text: item.owner == "ai" ? "AI" : "我",
                tint: item.owner == "ai" ? POSTheme.info : POSTheme.accent
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(planAccessibilityLabel(item)))
    }

    private func timeRange(start: String, end: String?) -> String {
        if let end {
            return "\(start)–\(end)"
        }
        return start
    }

    private func planAccessibilityLabel(_ item: PlanItem) -> String {
        var text = item.title
        if let start = item.startTime {
            text += "，\(start) 开始"
        }
        if item.status == "done" {
            text += "，已完成"
        } else if item.status == "skipped" {
            text += "，已跳过"
        }
        text += item.owner == "ai" ? "，助手负责" : "，我负责"
        return text
    }

    // MARK: - 下一项

    @ViewBuilder
    private var nextItemSection: some View {
        SectionCard(title: "下一项", systemImage: "arrow.right.circle") {
            if let next = nextItem {
                HStack(alignment: .top, spacing: POSTheme.Spacing.s) {
                    VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
                        Text(next.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(POSTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(nextItemSubtitle(next))
                            .font(.caption)
                            .foregroundStyle(POSTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    StatusPill(
                        text: next.owner == "ai" ? "AI 处理" : "我来做",
                        tint: next.owner == "ai" ? POSTheme.info : POSTheme.accent
                    )
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(todayPlan.isEmpty ? "今天没有待办项。" : "今天的待办都处理完了。")
                    .font(.subheadline)
                    .foregroundStyle(POSTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func nextItemSubtitle(_ item: PlanItem) -> String {
        if let start = item.startTime {
            return "从 \(start) 开始"
        }
        return "未设置开始时间"
    }

    // MARK: - 助手正在处理

    @ViewBuilder
    private var assistantSection: some View {
        SectionCard(
            title: "助手正在处理",
            systemImage: "sparkles",
            caption: activeTasks.isEmpty ? nil : "\(activeTasks.count) 项"
        ) {
            if activeTasks.isEmpty {
                Text(queuedChatText ?? "助手当前空闲。")
                    .font(.subheadline)
                    .foregroundStyle(POSTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
                    ForEach(activeTasks) { task in
                        HStack(spacing: POSTheme.Spacing.s) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: POSTheme.Spacing.xxs) {
                                Text(task.title)
                                    .font(.subheadline)
                                    .foregroundStyle(POSTheme.primaryText)
                                    .lineLimit(2)
                                Text("更新于 \(POSDate.relative(task.updatedAt))")
                                    .font(.caption)
                                    .foregroundStyle(POSTheme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            StatusPill(text: task.statusTitle, tint: task.bucket.tint)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("\(task.title)，\(task.statusTitle)"))
                    }
                }
            }
        }
    }

    private var queuedChatText: String? {
        guard let presence = model.presence, presence.queuedChat > 0 else { return nil }
        return "助手当前空闲，还有 \(presence.queuedChat) 条消息排队。"
    }

    // MARK: - 待我决定

    @ViewBuilder
    private var decisionsSection: some View {
        if !decisions.isEmpty {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
                Text("待我决定")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(POSTheme.primaryText)
                    .accessibilityAddTraits(.isHeader)

                ForEach(decisions) { task in
                    TaskCard(
                        task: task,
                        isBusy: model.pendingTaskActions.contains(task.id),
                        onApprove: approveAction(task),
                        onReject: rejectAction(task),
                        onAccept: acceptAction(task),
                        onRework: reworkAction(task)
                    )
                }
            }
        }
    }

    private func approveAction(_ task: TaskSummary) -> (() -> Void)? {
        guard task.isAwaitingApproval else { return nil }
        return {
            Task { await model.approve(taskID: task.id) }
        }
    }

    private func rejectAction(_ task: TaskSummary) -> (() -> Void)? {
        guard task.isAwaitingApproval else { return nil }
        return {
            Task { await model.reject(taskID: task.id, note: nil) }
        }
    }

    private func acceptAction(_ task: TaskSummary) -> (() -> Void)? {
        guard task.isAwaitingVerdict else { return nil }
        return {
            Task { await model.accept(taskID: task.id) }
        }
    }

    private func reworkAction(_ task: TaskSummary) -> (() -> Void)? {
        guard task.isAwaitingVerdict else { return nil }
        return {
            Task { await model.requestRework(taskID: task.id, note: nil) }
        }
    }

    // MARK: - 最近结果

    @ViewBuilder
    private var recentResultsSection: some View {
        if !recentResults.isEmpty {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
                Text("最近结果")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(POSTheme.primaryText)
                    .accessibilityAddTraits(.isHeader)

                ForEach(recentResults) { task in
                    TaskCard(task: task)
                }
            }
        }
    }
}
