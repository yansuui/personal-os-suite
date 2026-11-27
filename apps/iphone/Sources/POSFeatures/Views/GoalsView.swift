import Foundation
import SwiftUI
import POSCore

struct GoalsView: View {
    @ObservedObject var model: AppModel
    @State private var status: GoalStatus = .active
    @State private var editor: GoalDraftRoute?
    private var filteredGoals: [Goal] { model.goals.filter { $0.status == status } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                GoalSyncStatusView(model: model)
                GoalsErrorView(model: model)
                if !model.goalDrafts.isEmpty {
                    VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                        Text("保留的草稿").font(.headline)
                        ForEach(model.goalDrafts.values.sorted { $0.id < $1.id }) { draft in
                            Button { editor = GoalDraftRoute(id: draft.id, identity: model.cacheIdentityKey) } label: {
                                HStack {
                                    Text(draft.title.isEmpty ? draft.kind.displayTitle : draft.title).lineLimit(1)
                                    Spacer()
                                    Text(draft.hasUncertainResult ? "恢复保存" : "继续编辑").font(.caption)
                                }
                            }
                        }
                        Text(model.goalDraftStorageError == nil
                            ? "草稿仅在本机保存。离线不会自动提交，联网后请再次保存。"
                            : "最新更改未保存到本机，请重试保存；离线不会自动提交。")
                            .font(.caption).foregroundStyle(POSTheme.secondaryText)
                    }.posCard()
                }
                Picker("目标状态", selection: $status) {
                    ForEach(GoalStatus.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if model.isLoadingGoals && model.goals.isEmpty {
                    LoadingStateView(title: "正在同步目标…")
                } else if filteredGoals.isEmpty {
                    EmptyStateView(title: "还没有\(status.title)的目标",
                        message: model.goalsLastSyncedAt == nil ? "尚无此状态的离线数据。连接服务器后刷新，或先填写本机草稿。" : "可以创建目标，再在详情中拆分和推进任务。",
                        systemImage: "target")
                } else {
                    ForEach(filteredGoals) { goal in
                        NavigationLink { GoalDetailView(model: model, goalID: goal.id) } label: {
                            VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                                HStack {
                                    Text(goal.title).font(.headline).foregroundStyle(POSTheme.primaryText)
                                    Spacer()
                                    Text(goal.status.title).font(.caption).foregroundStyle(POSTheme.secondaryText)
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                if let description = goal.description, !description.isEmpty {
                                    Text(description).font(.subheadline).foregroundStyle(POSTheme.secondaryText).lineLimit(2)
                                }
                                if let summary = summary(for: goal) { GoalSummaryView(summary: summary) }
                                if let date = goal.targetDate { Label("目标日期：\(date)", systemImage: "calendar").font(.caption) }
                                Text("更新于 \(POSDate.shortStamp(summary(for: goal)?.latestUpdatedAt ?? goal.updatedAt))")
                                    .font(.caption).foregroundStyle(POSTheme.secondaryText)
                            }.frame(maxWidth: .infinity, alignment: .leading).posCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("目标")
        .task { model.setGoalsTabActive(model.selectedTab == 1); await model.refreshGoals() }
        .refreshable { await model.refreshGoalData() }
        .toolbar {
            RefreshToolbar(isRefreshing: model.isLoadingGoals) { Task { await model.refreshGoalData() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { open(GoalDraft(id: "new-goal", kind: .createGoal)) } label: { Label("新目标", systemImage: "plus") }
                    .disabled(!model.phase.isReady || model.goalsCapabilities?.supportsGoals == false)
            }
        }
        .sheet(item: $editor) { route in GoalDraftEditorView(model: model, route: route) }
    }

    private func summary(for goal: Goal) -> GoalTaskSummary? {
        if let detail = model.goalDetails[goal.id], detail.viewRevision >= (goal.viewRevision ?? 0) { return detail.summary }
        return goal.summary
    }
    private func open(_ draft: GoalDraft) {
        editor = GoalDraftRoute(id: model.beginGoalDraft(draft), identity: model.cacheIdentityKey)
    }
}

struct GoalDetailView: View {
    @ObservedObject var model: AppModel
    let goalID: String
    @State private var editor: GoalDraftRoute?
    private var detail: GoalDetail? { model.goalDetails[goalID] }
    private var goal: Goal? { model.goals.first { $0.id == goalID } ?? detail?.goal }
    private var isBusy: Bool { model.pendingGoalActions.contains(goalID) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                GoalSyncStatusView(model: model, asOf: detail?.asOf)
                GoalsErrorView(model: model)
                if let goal {
                    header(goal)
                    if let detail {
                        GoalSummaryView(summary: detail.summary).posCard()
                        HStack {
                            Text("任务").font(.title3.weight(.semibold))
                            Spacer()
                            Button { open(GoalDraft(id: "new-task:\(goalID)", kind: .createTask, goalID: goalID)) } label: {
                                Label("添加任务", systemImage: "plus")
                            }.disabled(isBusy || goal.status != .active)
                        }
                        if detail.tasks.isEmpty {
                            EmptyStateView(title: "还没有任务", message: "把目标拆成可以推进的小任务。", systemImage: "checklist")
                        }
                        ForEach(sorted(detail.tasks.filter { !$0.status.isTerminal })) { task in taskLink(task) }
                        if detail.tasks.contains(where: { $0.status.isTerminal }) {
                            DisclosureGroup("已完成与已取消（\(detail.tasks.filter { $0.status.isTerminal }.count)）") {
                                ForEach(sorted(detail.tasks.filter { $0.status.isTerminal })) { task in taskLink(task) }
                            }.font(.subheadline)
                        }
                        if goal.status == .active && !detail.tasks.isEmpty && detail.tasks.allSatisfy({ $0.status.isTerminal }) {
                            Text("任务均已结束。请根据完成标准明确确认是否完成目标。")
                                .font(.footnote).foregroundStyle(POSTheme.secondaryText)
                        }
                    } else if model.loadingGoalIDs.contains(goalID) {
                        LoadingStateView(title: "正在读取目标详情…")
                    } else {
                        EmptyStateView(title: "详情尚未同步", message: "连接服务器后刷新，读取此目标的任务和进展。", systemImage: "arrow.clockwise")
                    }
                    if model.supportsGoalQuestions {
                        Button { Task { await model.chatAboutGoal(goalID) } } label: {
                            Label("和助手聊这个目标", systemImage: "bubble.left.and.bubble.right")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(!model.canEditGoals || model.isCreatingConversation)
                    } else {
                        Text("服务器启用目标问答后，可从这里把本目标资料关联到聊天。")
                            .font(.footnote).foregroundStyle(POSTheme.secondaryText)
                    }
                } else {
                    EmptyStateView(title: "尚无目标详情", message: "连接服务器后刷新。", systemImage: "target")
                }
            }.padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("目标详情").navigationBarTitleDisplayMode(.inline)
        .task(id: goalID) { await model.loadGoal(goalID) }
        .onAppear { model.setVisibleGoal(goalID) }
        .onDisappear { model.setVisibleGoal(nil) }
        .refreshable { await model.refreshGoalData(goalID: goalID) }
        .toolbar {
            RefreshToolbar(isRefreshing: model.loadingGoalIDs.contains(goalID)) {
                Task { await model.refreshGoalData(goalID: goalID) }
            }
        }
        .sheet(item: $editor) { route in GoalDraftEditorView(model: model, route: route) }
    }

    private func header(_ goal: Goal) -> some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
            Text(goal.title).font(.title2.weight(.semibold))
            Text(goal.status.title).foregroundStyle(POSTheme.secondaryText)
            if let description = goal.description, !description.isEmpty { Text(description) }
            if let criteria = goal.successCriteria, !criteria.isEmpty {
                Text("完成标准").font(.subheadline.weight(.semibold))
                Text(criteria).foregroundStyle(POSTheme.secondaryText)
            }
            if let date = goal.targetDate { Label("目标日期：\(date)", systemImage: "calendar") }
            Text("更新于 \(POSDate.shortStamp(goal.updatedAt))").font(.caption).foregroundStyle(POSTheme.secondaryText)
            if goal.status != .active {
                Text("此目标只读，需要继续工作时先恢复或重新开启。")
                    .font(.footnote).foregroundStyle(POSTheme.secondaryText)
            }
            Menu("目标操作") {
                switch goal.status {
                case .active:
                    Button("编辑目标") {
                        open(GoalDraft(id: "goal:\(goalID):edit", kind: .editGoal, goalID: goalID,
                            expectedRevision: goal.revision, title: goal.title, description: goal.description ?? "",
                            successCriteria: goal.successCriteria ?? "", date: goal.targetDate ?? ""))
                    }
                    Button("标记完成") { action(goal, .complete) }
                        .disabled(detail == nil || detail?.tasks.contains(where: { !$0.status.isTerminal }) == true)
                    Button("归档") { action(goal, .archive) }
                case .completed:
                    Button("重新开启") { action(goal, .reopen) }
                    Button("归档") { action(goal, .archive) }
                case .archived:
                    Button("恢复目标") { action(goal, .restore) }
                }
            }.disabled(isBusy)
        }.frame(maxWidth: .infinity, alignment: .leading).posCard()
    }

    private func taskLink(_ task: GoalTask) -> some View {
        NavigationLink { GoalTaskDetailView(model: model, initialTask: task) } label: {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                HStack {
                    Text(task.title).font(.headline).foregroundStyle(POSTheme.primaryText)
                    Spacer()
                    Text(task.status.title).font(.caption)
                        .foregroundStyle(task.status == .blocked ? POSTheme.warning : POSTheme.secondaryText)
                }
                if let date = task.dueDate { Label("截止：\(date)", systemImage: "calendar").font(.caption) }
                if task.status == .blocked, let reason = task.blockedReason {
                    Text("受阻原因：\(reason)").font(.subheadline).foregroundStyle(POSTheme.warning)
                }
                Text("更新于 \(POSDate.shortStamp(task.updatedAt))").font(.caption).foregroundStyle(POSTheme.secondaryText)
            }.frame(maxWidth: .infinity, alignment: .leading).posCard()
        }.buttonStyle(.plain)
    }
    private func sorted(_ tasks: [GoalTask]) -> [GoalTask] {
        let order: [GoalTaskStatus: Int] = [.blocked: 0, .inProgress: 1, .todo: 2, .completed: 3, .canceled: 4]
        return tasks.sorted {
            let first = order[$0.status, default: 5], second = order[$1.status, default: 5]
            return first == second ? ($0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt) : first < second
        }
    }
    private func action(_ goal: Goal, _ action: GoalAction) {
        open(GoalDraft.forGoalAction(goal, action: action))
    }
    private func open(_ draft: GoalDraft) {
        editor = GoalDraftRoute(id: model.beginGoalDraft(draft), identity: model.cacheIdentityKey)
    }
}

struct GoalTaskDetailView: View {
    @ObservedObject var model: AppModel
    let initialTask: GoalTask
    @State private var editor: GoalDraftRoute?
    private var detail: GoalTaskDetail? { model.goalTaskDetails[initialTask.id] }
    private var task: GoalTask {
        let candidates = [initialTask, detail?.task, model.goalDetails[initialTask.goalId]?.tasks.first { $0.id == initialTask.id }].compactMap { $0 }
        return candidates.max { $0.revision < $1.revision } ?? initialTask
    }
    private var editable: Bool {
        (model.goals.first { $0.id == task.goalId } ?? model.goalDetails[task.goalId]?.goal)?.status == .active
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.l) {
                GoalSyncStatusView(model: model, asOf: model.goalDetails[task.goalId]?.asOf)
                GoalsErrorView(model: model)
                VStack(alignment: .leading, spacing: POSTheme.Spacing.m) {
                    Text(task.title).font(.title2.weight(.semibold))
                    Text(task.status.title).foregroundStyle(task.status == .blocked ? POSTheme.warning : POSTheme.secondaryText)
                    if let description = task.description, !description.isEmpty { Text(description) }
                    if let date = task.dueDate { Label("截止日期：\(date)", systemImage: "calendar") }
                    if let reason = task.blockedReason { Text("受阻原因：\(reason)").foregroundStyle(POSTheme.warning) }
                    if let result = task.resultNote { Text("结果说明：\(result)") }
                    Text("更新于 \(POSDate.shortStamp(task.updatedAt))").font(.caption).foregroundStyle(POSTheme.secondaryText)
                    if editable {
                        HStack {
                            Button("编辑正文") {
                                open(GoalDraft(id: "task:\(task.id):edit", kind: .editTask, goalID: task.goalId,
                                    taskID: task.id, expectedRevision: task.revision, title: task.title,
                                    description: task.description ?? "", date: task.dueDate ?? ""))
                            }.disabled(task.status.isTerminal)
                            Button("记录进展") {
                                open(GoalDraft(id: "task:\(task.id):progress", kind: .taskProgress, goalID: task.goalId,
                                    taskID: task.id, expectedRevision: task.revision, title: task.title))
                            }.disabled(task.status.isTerminal)
                            Menu(task.status.isTerminal ? "重新打开" : "更改状态") {
                                ForEach(task.status.nextStatuses) { status in
                                    Button(status == .todo && task.status.isTerminal ? "重开为待做" : status.title) {
                                        open(GoalDraft.forTaskStatus(task, status: status))
                                    }
                                }
                            }
                        }.font(.subheadline).disabled(model.pendingGoalActions.contains(task.goalId))
                    } else {
                        Text("目标当前只读，恢复目标后才能更改任务。")
                            .font(.footnote).foregroundStyle(POSTheme.secondaryText)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).posCard()
                Text("进展记录").font(.title3.weight(.semibold))
                if let detail {
                    if detail.task.revision < task.revision {
                        Text("进展尚未同步到当前状态，请刷新。")
                            .font(.footnote).foregroundStyle(POSTheme.warning)
                    }
                    if detail.nextCursor != nil {
                        Text("仅显示最早的 \(detail.progressEntries.count) 条进展，已达到本机读取上限；后续记录未纳入。")
                            .font(.footnote).foregroundStyle(POSTheme.warning)
                    }
                    if detail.progressEntries.isEmpty { Text("暂无进展记录").foregroundStyle(POSTheme.secondaryText) }
                    ForEach(detail.progressEntries.reversed()) { entry in GoalProgressEntryView(entry: entry) }
                } else if model.loadingGoalTaskIDs.contains(task.id) {
                    LoadingStateView(title: "正在读取进展…")
                } else {
                    Text("尚无已缓存的进展记录，联网刷新后可查看。")
                        .font(.footnote).foregroundStyle(POSTheme.secondaryText)
                }
            }.padding(POSTheme.Spacing.l)
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
        .task(id: initialTask.id) { await model.loadGoalTask(initialTask.id) }
        .onAppear { model.setVisibleGoalTask(initialTask.id) }
        .onDisappear { model.setVisibleGoalTask(nil) }
        .refreshable { await model.refreshGoalData(goalID: task.goalId, taskID: task.id) }
        .sheet(item: $editor) { route in GoalDraftEditorView(model: model, route: route) }
    }
    private func open(_ draft: GoalDraft) {
        editor = GoalDraftRoute(id: model.beginGoalDraft(draft), identity: model.cacheIdentityKey)
    }
}

struct GoalSummaryView: View {
    let summary: GoalTaskSummary
    var body: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
            if summary.activeTasks > 0 {
                ProgressView(value: Double(summary.completedTasks), total: Double(summary.activeTasks))
                    .accessibilityLabel("任务完成进度")
                Text("完成 \(summary.completedTasks)/\(summary.activeTasks) 项有效任务").font(.subheadline)
            } else {
                Text(summary.canceledTasks > 0 ? "无有效任务" : "暂无任务").font(.subheadline)
            }
            Text("受阻 \(summary.blockedTasks) · 已取消 \(summary.canceledTasks)")
                .font(.caption).foregroundStyle(POSTheme.secondaryText)
            if let todo = summary.todoTasks, let progressing = summary.inProgressTasks {
                Text("待做 \(todo) · 进行中 \(progressing)").font(.caption).foregroundStyle(POSTheme.secondaryText)
            }
        }
    }
}

struct GoalProgressEntryView: View {
    let entry: GoalProgressEntry
    var body: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
            if let to = entry.toStatus {
                Text(entry.fromStatus.map { "\($0.title) → \(to.title)" } ?? "创建为\(to.title)").font(.subheadline.weight(.semibold))
            } else { Text(entry.kind == .result ? "结果说明" : "进展备注").font(.subheadline.weight(.semibold)) }
            if let note = entry.note, !note.isEmpty { Text(note).font(.subheadline) }
            Text(POSDate.shortStamp(entry.createdAt)).font(.caption).foregroundStyle(POSTheme.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading).posCard()
    }
}

struct GoalSyncStatusView: View {
    @ObservedObject var model: AppModel
    var asOf: String? = nil
    var body: some View {
        let stamp = POSDate.shortStamp(asOf ?? model.goalsLastSyncedAt)
        Text(model.goalsOnline && model.connection.isOnline
            ? "已同步 · \(stamp.isEmpty ? "刚刚" : stamp)"
            : "离线 / 尚未同步 · \(stamp.isEmpty ? "尚无离线数据" : "上次同步 " + stamp)")
            .font(.caption).foregroundStyle(POSTheme.secondaryText)
    }
}

struct GoalsErrorView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GoalDraftStorageErrorView(model: model)
        if let error = model.goalsError { ErrorBanner(message: error, tint: POSTheme.warning, onDismiss: { model.dismissGoalsError() }) }
    }
}

struct GoalDraftStorageErrorView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let error = model.goalDraftStorageError {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                Text(error).font(.footnote).foregroundStyle(POSTheme.warning)
                Button("重试保存到本机") { model.persistGoalDraftsLocally(identity: model.cacheIdentityKey) }
                    .font(.footnote)
            }
        }
    }
}

struct GoalDraftRoute: Identifiable { let id: String; let identity: String }

private extension GoalDraftKind {
    var displayTitle: String {
        switch self {
        case .createGoal: return "新目标"
        case .editGoal: return "编辑目标"
        case .goalAction: return "更改目标状态"
        case .createTask: return "添加任务"
        case .editTask: return "编辑任务"
        case .taskStatus: return "更改任务状态"
        case .taskProgress: return "记录进展"
        }
    }
}

struct GoalDraftEditorView: View {
    @ObservedObject var model: AppModel
    let route: GoalDraftRoute
    @Environment(\.dismiss) private var dismiss
    private var draft: GoalDraft? { route.identity == model.cacheIdentityKey ? model.goalDrafts[route.id] : nil }
    private var isBusy: Bool { model.isGoalDraftSaving(route.id) }

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    if model.goalDraftStorageError != nil { Section { GoalDraftStorageErrorView(model: model) } }
                    if let error = draft.error { Section { Text(error).foregroundStyle(POSTheme.warning) } }
                    if !model.canEditGoals {
                        Section {
                            Text("当前只保留本机草稿；连接并刷新服务器后，才能确认保存到云端。").font(.footnote)
                            Button("重新连接并刷新") { Task { await model.refreshGoalData() } }
                                .disabled(model.isRefreshing || model.isLoadingGoals)
                        }
                    }
                    if draft.isLocked {
                        Section {
                            Text(draft.hasUncertainResult ? "原操作已固定。恢复保存会复用同一次请求；确认结果前不能更换输入。" : "原操作被服务器拒绝，输入仍保留。请核对最新内容后再继续编辑。")
                                .font(.footnote)
                        }
                    }
                    fields(draft).disabled(draft.isLocked || isBusy)
                    if draft.state == .conflict || draft.state == .rejected {
                        latestContent(draft)
                        Section {
                            Button("保留输入，按最新内容继续编辑") {
                                Task { await model.reviseGoalDraft(route.id, identity: route.identity) }
                            }.disabled(!model.canEditGoals || isBusy)
                        }
                    }
                    if !draft.hasUncertainResult {
                        Section {
                            Button("丢弃这份草稿", role: .destructive) {
                                model.discardGoalDraft(route.id, identity: route.identity); dismiss()
                            }.disabled(isBusy)
                        }
                    }
                } else { Text("这份草稿已处理，或当前身份已变化。") }
            }
            .navigationTitle(draft?.kind.displayTitle ?? "草稿")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.goalDraftStorageError == nil ? "关闭并保留" : "关闭（更改未存盘）") { dismiss() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isBusy ? "保存中…" : (draft?.hasUncertainResult == true ? "恢复保存" : "保存")) {
                        Task { if await model.submitGoalDraft(route.id, identity: route.identity) { dismiss() } }
                    }.disabled(isBusy || !model.canEditGoals || draft?.isValid != true || draft?.state == .conflict || draft?.state == .rejected)
                }
            }
            .interactiveDismissDisabled(isBusy)
        }
    }

    @ViewBuilder private func fields(_ draft: GoalDraft) -> some View {
        switch draft.kind {
        case .createGoal, .editGoal, .createTask, .editTask:
            Section(draft.kind == .createGoal || draft.kind == .editGoal ? "目标" : "任务") {
                TextField("名称（必填）", text: text(\.title))
                TextField("说明（可选）", text: text(\.description), axis: .vertical).lineLimit(3...6)
                if draft.kind == .createGoal || draft.kind == .editGoal {
                    TextField("完成标准（可选）", text: text(\.successCriteria), axis: .vertical).lineLimit(2...5)
                }
                TextField(draft.kind == .createGoal || draft.kind == .editGoal ? "目标日期 YYYY-MM-DD" : "截止日期 YYYY-MM-DD", text: text(\.date))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("日期为自然日；留空表示无日期，编辑时留空会清除已有日期。")
                    .font(.caption).foregroundStyle(POSTheme.secondaryText)
                if !draft.date.isEmpty && !GoalDraft.isNaturalDate(draft.date.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Text("请填写有效日期，例如 2026-12-01。日期不代表定时提醒。")
                        .font(.caption).foregroundStyle(POSTheme.warning)
                }
            }
        case .goalAction:
            Section(draft.title) {
                Text(goalActionTitle(draft.goalAction))
                Text("此操作需由服务器确认。任务不会因聊天完成而自动完成。")
                    .font(.footnote).foregroundStyle(POSTheme.secondaryText)
            }
        case .taskStatus:
            Section(draft.title) {
                Text("新状态：\(draft.status?.title ?? "未选择")")
                TextField(draft.status == .blocked ? "受阻原因（必填）" : "备注（可选）", text: text(\.note), axis: .vertical).lineLimit(2...6)
                if draft.status == .completed {
                    TextField("结果说明（可选）", text: text(\.resultNote), axis: .vertical).lineLimit(2...6)
                }
            }
        case .taskProgress:
            Section(draft.title) { TextField("进展说明（必填）", text: text(\.note), axis: .vertical).lineLimit(4...8) }
        }
    }

    @ViewBuilder private func latestContent(_ draft: GoalDraft) -> some View {
        Section("服务器最新内容") {
            if let taskID = draft.taskID, let task = model.goalTaskDetails[taskID]?.task {
                Text(task.title).font(.headline)
                Text(task.status.title)
                if let description = task.description { Text(description) }
                if let date = task.dueDate { Text("截止日期：\(date)") }
                if let reason = task.blockedReason { Text("受阻原因：\(reason)") }
                if let result = task.resultNote { Text("结果：\(result)") }
            } else if let goalID = draft.goalID, let goal = model.goals.first(where: { $0.id == goalID }) {
                Text(goal.title).font(.headline)
                Text(goal.status.title)
                if let description = goal.description { Text(description) }
                if let criteria = goal.successCriteria { Text("完成标准：\(criteria)") }
                if let date = goal.targetDate { Text("目标日期：\(date)") }
            } else { Text("请先刷新服务器内容。") }
        }
    }

    private func text(_ keyPath: WritableKeyPath<GoalDraft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: keyPath] ?? "" }, set: { value in
            guard var draft else { return }
            draft[keyPath: keyPath] = value
            model.updateGoalDraft(draft, identity: route.identity)
        })
    }
    private func goalActionTitle(_ action: GoalAction?) -> String {
        switch action {
        case .complete: return "将目标标记为已完成"
        case .archive: return "将目标归档并保留历史"
        case .restore: return "恢复为归档前状态"
        case .reopen: return "重新开启为进行中"
        default: return "更新目标"
        }
    }
}
