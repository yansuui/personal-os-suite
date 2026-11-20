import SwiftUI
import POSCore

/// 任务卡片：标题、状态、更新时间、错误/输出摘要，按上下文显示审批或验收按钮。
struct TaskCard: View {
    let task: TaskSummary
    var isBusy: Bool = false
    var onApprove: (() -> Void)? = nil
    var onReject: (() -> Void)? = nil
    var onAccept: (() -> Void)? = nil
    var onRework: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: POSTheme.Spacing.s) {
            HStack(alignment: .top, spacing: POSTheme.Spacing.s) {
                Text(task.title)
                    .font(.headline)
                    .foregroundStyle(POSTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                StatusPill(
                    text: task.statusTitle,
                    tint: task.bucket.tint,
                    systemImage: task.bucket.systemImage
                )
            }

            HStack(spacing: POSTheme.Spacing.s) {
                Label("更新于 \(POSDate.relative(task.updatedAt))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(POSTheme.secondaryText)
                    .labelStyle(.titleAndIcon)

                if let verdictTitle = task.verdictTitle {
                    StatusPill(
                        text: verdictTitle,
                        tint: task.verdict == "accepted" ? POSTheme.success : POSTheme.warning
                    )
                }

                Spacer(minLength: 0)
            }

            if let errorText = task.errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(POSTheme.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let outputTail = task.outputTail, !outputTail.isEmpty {
                Text(outputTail)
                    .font(.caption.monospaced())
                    .foregroundStyle(POSTheme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionRow
        }
        .posCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionRow: some View {
        if onApprove != nil || onReject != nil || onAccept != nil || onRework != nil {
            HStack(spacing: POSTheme.Spacing.s) {
                if let onReject {
                    ActionButton(
                        title: "拒绝",
                        systemImage: "xmark",
                        variant: .secondary,
                        isBusy: isBusy,
                        accessibility: "拒绝任务 \(task.title)",
                        action: onReject
                    )
                }
                if let onApprove {
                    ActionButton(
                        title: "批准",
                        systemImage: "checkmark",
                        variant: .primary,
                        isBusy: isBusy,
                        accessibility: "批准任务 \(task.title)",
                        action: onApprove
                    )
                }
                if let onRework {
                    ActionButton(
                        title: "返工",
                        systemImage: "arrow.uturn.backward",
                        variant: .secondary,
                        isBusy: isBusy,
                        accessibility: "要求任务 \(task.title) 返工",
                        action: onRework
                    )
                }
                if let onAccept {
                    ActionButton(
                        title: "接受",
                        systemImage: "checkmark.seal",
                        variant: .primary,
                        isBusy: isBusy,
                        accessibility: "接受任务 \(task.title) 的结果",
                        action: onAccept
                    )
                }
            }
            .padding(.top, POSTheme.Spacing.xs)
        }
    }
}
