import Foundation
import SwiftUI
import POSCore

/// 任务：按状态分组（等待设备 / 等待审批 / 执行中 / 待验收 / 失败 / 已结束）。
struct TasksView: View {
    @ObservedObject var model: AppModel

    @State private var rejectTarget: TaskSummary?
    @State private var rejectNote: String = ""
    @State private var reworkTarget: TaskSummary?
    @State private var reworkNote: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                if let notice = model.notice {
                    ErrorBanner(
                        message: notice,
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

                content
            }
            .padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("任务")
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            RefreshToolbar(isRefreshing: model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
        .alert("拒绝任务", isPresented: isPresented($rejectTarget), presenting: rejectTarget) { task in
            TextField("拒绝原因（可选，最多 500 字）", text: $rejectNote)
            Button("取消", role: .cancel) {
                rejectNote = ""
            }
            Button("拒绝", role: .destructive) {
                let note = normalizedNote(rejectNote)
                rejectNote = ""
                Task { await model.reject(taskID: task.id, note: note) }
            }
        } message: { task in
            Text("「\(task.title)」将不会被批准执行。")
        }
        .alert("要求返工", isPresented: isPresented($reworkTarget), presenting: reworkTarget) { task in
            TextField("返工说明（可选，最多 500 字）", text: $reworkNote)
            Button("取消", role: .cancel) {
                reworkNote = ""
            }
            Button("提交") {
                let note = normalizedNote(reworkNote)
                reworkNote = ""
                Task { await model.requestRework(taskID: task.id, note: note) }
            }
        } message: { task in
            Text("「\(task.title)」的验收结论会记为 rejected。")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if model.tasks.isEmpty {
            if model.isRefreshing {
                LoadingStateView(title: "正在同步任务…")
            } else {
                EmptyStateView(
                    title: "还没有任务",
                    message: "助手接到的任务会实时同步到这里。",
                    systemImage: "checklist",
                    actionTitle: "刷新",
                    action: { Task { await model.refresh() } }
                )
            }
        } else {
            ForEach(TaskBucket.allCases) { bucket in
                let items = groupedTasks[bucket] ?? []
                if !items.isEmpty {
                    section(bucket: bucket, items: items)
                }
            }
        }
    }

    private var groupedTasks: [TaskBucket: [TaskSummary]] {
        Dictionary(grouping: model.tasks, by: { $0.bucket })
            .mapValues { tasks in
                tasks.sorted(by: POSCoreBridge.taskOrder)
            }
    }

    private func section(bucket: TaskBucket, items: [TaskSummary]) -> some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
            HStack(spacing: POSTheme.Spacing.s) {
                Image(systemName: bucket.systemImage)
                    .foregroundStyle(bucket.tint)
                    .accessibilityHidden(true)
                Text(bucket.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(POSTheme.primaryText)
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(POSTheme.secondaryText)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(items) { task in
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

    // MARK: - 操作

    private func approveAction(_ task: TaskSummary) -> (() -> Void)? {
        guard task.isAwaitingApproval else { return nil }
        return {
            Task { await model.approve(taskID: task.id) }
        }
    }

    private func rejectAction(_ task: TaskSummary) -> (() -> Void)? {
        guard task.isAwaitingApproval else { return nil }
        return {
            self.rejectNote = ""
            self.rejectTarget = task
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
            self.reworkNote = ""
            self.reworkTarget = task
        }
    }

    // MARK: - 辅助

    /// 把可选数据转成 alert 需要的 Bool 绑定。
    private func isPresented(_ binding: Binding<TaskSummary?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue != nil },
            set: { newValue in
                if !newValue {
                    binding.wrappedValue = nil
                }
            }
        )
    }

    private func normalizedNote(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return String(trimmed.prefix(500))
    }
}
