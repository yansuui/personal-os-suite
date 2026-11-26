import Foundation
import SwiftUI
import POSCore

/// 助手：消息列表（自动滚到底）、输入框、连接状态横幅、断线重试。
struct AssistantView: View {
    @ObservedObject var model: AppModel

    private static let bottomAnchorID = "assistant-bottom-anchor"

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(model: model)

            if let notice = model.notice {
                ErrorBanner(
                    message: notice,
                    tint: POSTheme.warning,
                    onDismiss: { model.dismissNotice() }
                )
                .padding(.horizontal, POSTheme.Spacing.l)
                .padding(.top, POSTheme.Spacing.s)
            }

            conversationPicker
            messageList
            pendingMessages
            composer
        }
        .background(POSTheme.pageBackground)
        .navigationTitle("助手")
        .toolbar {
            RefreshToolbar(isRefreshing: model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
    }

    private var conversationPicker: some View {
        HStack {
            Menu {
                ForEach(model.conversations) { conversation in
                    Button(conversation.title ?? "未命名会话") {
                        model.selectConversation(conversation.id)
                    }
                }
            } label: {
                Label(model.selectedConversation?.title ?? (model.selectedConversationID == nil ? "选择会话" : "未命名会话"),
                      systemImage: "bubble.left.and.bubble.right")
                    .lineLimit(1)
            }
            .disabled(model.conversations.isEmpty)
            Spacer()
            Button {
                Task { await model.createConversation() }
            } label: {
                Label(model.isCreatingConversation ? "创建中…" : "新会话", systemImage: "plus")
            }
            .disabled(model.isCreatingConversation)
        }
        .padding(POSTheme.Spacing.m)
    }

    @ViewBuilder
    private var pendingMessages: some View {
        if !model.currentPendingMessages.isEmpty {
            VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                Text("发送或运行回执待确认（重试沿用原消息）")
                    .font(.caption)
                ForEach(model.currentPendingMessages) { pending in
                    HStack {
                        Text(pending.text).lineLimit(2)
                        Spacer()
                        Button(model.messages.contains(where: { $0.role == "user" && $0.clientRequestID == pending.clientRequestID }) ? "恢复状态" : "重试") {
                            Task { await model.retryPending(pending) }
                        }
                        .disabled(model.isSending)
                    }
                }
            }
            .padding(POSTheme.Spacing.m)
            .background(POSTheme.cardAlt)
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                    if model.messages.isEmpty {
                        EmptyStateView(
                            title: "和助手聊聊",
                            message: "发送消息后可查看生成状态；断网时也能看到本地缓存的历史。",
                            systemImage: "bubble.left.and.bubble.right"
                        )
                    }

                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
                            MessageBubble(message: message)
                            if let record = model.currentRunRecords.first(where: { $0.messageID == message.id }) {
                                runStatus(record)
                            }
                        }
                        .id(message.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(POSTheme.Spacing.l)
            }
            .refreshable {
                await model.refresh()
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: model.messages.last?.id) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    private func runStatus(_ record: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.xs) {
            HStack(spacing: POSTheme.Spacing.s) {
                if !record.status.isTerminal {
                    ProgressView().controlSize(.mini)
                }
                Text(record.status.title)
                    .font(.caption)
                    .foregroundStyle(record.status == .failed ? POSTheme.warning : POSTheme.secondaryText)
                Spacer()
                if !record.status.isTerminal {
                    Button(model.cancelingRunIDs.contains(record.id) ? "取消中…" : "取消") {
                        Task { await model.cancelRun(record.id) }
                    }
                    .disabled(model.cancelingRunIDs.contains(record.id))
                    .font(.caption)
                }
            }
            if record.status == .failed {
                Text(record.serverError ?? "生成失败，请重新发送消息。")
                    .font(.caption).foregroundStyle(POSTheme.warning)
            }
            if let error = record.cancellationError {
                Text(error).font(.caption).foregroundStyle(POSTheme.warning)
            }
            if let error = record.pollingError, !record.status.isTerminal {
                Text("状态暂未更新：" + error).font(.caption).foregroundStyle(POSTheme.warning)
                Button("刷新状态") { Task { await model.refreshRunStates() } }.font(.caption)
            }
        }
        .padding(.horizontal, POSTheme.Spacing.s)
        .accessibilityElement(children: .contain)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - 输入框

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: POSTheme.Spacing.s) {
                TextField("描述你要做的事…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
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
                    .accessibilityLabel(Text("消息输入框"))
                    .disabled(!model.phase.isReady)

                Button(action: send) {
                    Group {
                        if model.isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? POSTheme.accent : POSTheme.tertiaryText)
                .disabled(!canSend)
                .accessibilityLabel(Text(model.isSending ? "正在发送" : "发送消息"))
            }
            .padding(.horizontal, POSTheme.Spacing.l)
            .padding(.vertical, POSTheme.Spacing.s)
        }
        .background(.bar)
    }

    private var canSend: Bool {
        guard model.phase.isReady, model.selectedConversationID != nil, !model.isSending else { return false }
        return !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = model.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isSending else { return }
        // 先清空输入框；发送失败时 AppModel 会把草稿回填回来。
        model.draft = ""
        Task { await model.send(text) }
    }
}
