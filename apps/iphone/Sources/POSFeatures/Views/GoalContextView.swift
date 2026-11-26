import SwiftUI
import POSCore

/// 本页只接受服务端为 run 固定的资料；不读取目标详情作为回答依据。
struct GoalContextView: View {
    @ObservedObject var model: AppModel
    let runID: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                if let context = model.goalContexts[runID] {
                    VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                        Text(context.goal.title).font(.title2.weight(.semibold))
                        Text("本次回答资料时间：\(POSDate.shortStamp(context.asOf))")
                            .font(.footnote).foregroundStyle(POSTheme.secondaryText)
                        Text("这是提问时固定的资料快照。之后更新目标或任务，不会改变本次依据。")
                            .font(.footnote).foregroundStyle(POSTheme.secondaryText)
                        Text("目标状态：\(context.goal.status.title)").font(.subheadline)
                        if let description = context.goal.description { Text(description) }
                        if let criteria = context.goal.successCriteria { Text("完成标准：\(criteria)") }
                        if let date = context.goal.targetDate { Text("目标日期：\(date)") }
                    }.frame(maxWidth: .infinity, alignment: .leading).posCard()
                    GoalSummaryView(summary: context.summary).posCard()
                    VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                        Text("资料范围").font(.headline)
                        Text("已纳入 \(context.includedTasks.count) 项任务明细。统计由服务器按全部任务计算。")
                        Text("未纳入 \(context.omissions.taskCount) 项任务明细、\(context.omissions.progressEntryCount) 条进展记录。")
                        if !context.omissions.truncatedFields.isEmpty {
                            Text("部分正文有截断：\(context.omissions.truncatedFields.joined(separator: "、"))")
                        }
                        ForEach(context.omissions.reasons, id: \.self) { reason in
                            Text(reasonTitle(reason)).font(.caption)
                        }
                        Text("任务与进展为有界资料；未纳入的内容不能当作已逐条核对。")
                            .font(.caption).foregroundStyle(POSTheme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading).posCard()
                    ForEach(context.includedTasks, id: \.task.id) { item in
                        VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                            Text(item.task.title).font(.headline)
                            Text("任务 ID：\(item.task.id)").font(.caption).textSelection(.enabled)
                            Text("状态：\(item.task.status.title)").font(.subheadline)
                            if let description = item.task.description { Text(description).font(.subheadline) }
                            if let date = item.task.dueDate { Text("截止日期：\(date)").font(.caption) }
                            if let reason = item.task.blockedReason { Text("受阻原因：\(reason)").foregroundStyle(POSTheme.warning) }
                            if let result = item.task.resultNote { Text("结果说明：\(result)") }
                            Text("最近更新：\(POSDate.shortStamp(item.task.updatedAt))")
                                .font(.caption).foregroundStyle(POSTheme.secondaryText)
                            ForEach(item.progressEntries) { entry in GoalProgressEntryView(entry: entry) }
                        }.frame(maxWidth: .infinity, alignment: .leading).posCard()
                    }
                } else if model.loadingGoalContextIDs.contains(runID) {
                    LoadingStateView(title: "正在读取本次回答依据…")
                } else {
                    Text(model.goalContextErrors[runID] ?? "本次资料尚未缓存，连接服务器后可读取。")
                        .foregroundStyle(POSTheme.warning)
                    Button("重试读取本次依据") { Task { await model.loadGoalContext(runID) } }
                }
            }.padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("本次回答依据").navigationBarTitleDisplayMode(.inline)
        .task(id: runID) { await model.loadGoalContext(runID) }
        .refreshable { await model.loadGoalContext(runID) }
    }

    private func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "task_limit": return "任务明细达到读取数量上限。"
        case "context_size", "context_size_limit", "character_limit": return "资料达到正文长度上限。"
        case "progress_limit": return "仅纳入每项任务最近的部分进展。"
        case "text_truncated": return "部分正文已按长度上限截断。"
        default: return reason
        }
    }
}
