import SwiftUI
import POSCore

/// 任务分组。顺序即界面分组顺序。
enum TaskBucket: String, CaseIterable, Identifiable {
    case waitingDevice
    case waitingApproval
    case running
    case waitingVerdict
    case failed
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waitingDevice:
            return "等待设备"
        case .waitingApproval:
            return "等待审批"
        case .running:
            return "执行中"
        case .waitingVerdict:
            return "待验收"
        case .failed:
            return "失败"
        case .finished:
            return "已结束"
        }
    }

    var systemImage: String {
        switch self {
        case .waitingDevice:
            return "desktopcomputer"
        case .waitingApproval:
            return "hand.raised"
        case .running:
            return "play.circle"
        case .waitingVerdict:
            return "checkmark.seal"
        case .failed:
            return "exclamationmark.triangle"
        case .finished:
            return "archivebox"
        }
    }

    var tint: Color {
        switch self {
        case .waitingDevice:
            return POSTheme.info
        case .waitingApproval:
            return POSTheme.warning
        case .running:
            return POSTheme.accent
        case .waitingVerdict:
            return POSTheme.success
        case .failed:
            return POSTheme.danger
        case .finished:
            return POSTheme.secondaryText
        }
    }
}

extension TaskSummary {
    /// 归组口径（与服务端状态 + requiresApproval 对齐）：
    /// - 需要批准或 `awaiting_approval` / `waiting-approval` → 等待审批（优先，避免审批卡落到别的组）；
    /// - `queued`（还没被任何 worker 领走）或 `waiting-device` → 等待设备；
    /// - `running` → 执行中；
    /// - `completed` 且无验收结论 → 待验收；
    /// - `failed` → 失败；
    /// - 其余（已验收 / 已取消 / 未知）→ 已结束。
    var bucket: TaskBucket {
        if requiresApproval || status == "awaiting_approval" || status == "waiting-approval" {
            return .waitingApproval
        }
        switch status {
        case "queued", "waiting-device":
            return .waitingDevice
        case "running":
            return .running
        case "completed":
            return verdict == nil ? .waitingVerdict : .finished
        case "failed":
            return .failed
        default:
            return .finished
        }
    }

    /// 状态中文名。
    var statusTitle: String {
        if requiresApproval && status != "awaiting_approval" && status != "waiting-approval"
            && status != "completed" && status != "failed" && status != "canceled" {
            return "等待审批"
        }
        switch status {
        case "queued":
            return "排队中（等待设备）"
        case "running":
            return "执行中"
        case "waiting-device":
            return "等待设备"
        case "awaiting_approval", "waiting-approval":
            return "等待审批"
        case "completed":
            return "已完成"
        case "failed":
            return "失败"
        case "canceled":
            return "已取消"
        default:
            return "未知状态"
        }
    }

    /// 验收结论文案，没有结论返回 nil。
    var verdictTitle: String? {
        switch verdict {
        case .some("accepted"):
            return "已接受"
        case .some("rejected"):
            return "已返工"
        default:
            return nil
        }
    }

    /// 是否需要「批准 / 拒绝」按钮。
    var isAwaitingApproval: Bool {
        bucket == .waitingApproval
    }

    /// 是否需要「接受 / 返工」按钮。
    var isAwaitingVerdict: Bool {
        bucket == .waitingVerdict
    }
}
