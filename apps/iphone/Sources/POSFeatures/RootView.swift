import SwiftUI

/// 应用根视图：按 `AppModel.phase` 在配对流程与五个 Tab 之间切换。
///
/// 契约要求：`public init(model: AppModel)` + `public var body`；
/// 内部使用 `@ObservedObject` 消费 `AppModel`（与契约 §5 的 `@StateObject` 侧配合）。
public struct RootView: View {

    @ObservedObject private var model: AppModel

    public init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            if model.phase.isReady {
                MainTabView(model: model)
            } else {
                OnboardingView(model: model)
            }
        }
        .tint(POSTheme.accent)
        .task {
            await model.bootstrap()
        }
    }
}

// MARK: - 主界面

/// 底部五个 Tab：今日 / 助手 / 任务 / 记忆 / 我的。
struct MainTabView: View {
    @ObservedObject var model: AppModel
    @State private var selection: Tab = .today

    enum Tab: Hashable {
        case today
        case assistant
        case tasks
        case memory
        case me
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                TodayView(model: model)
            }
            .tabItem {
                Label("今日", systemImage: "sun.max")
            }
            .tag(Tab.today)

            NavigationStack {
                AssistantView(model: model)
            }
            .tabItem {
                Label("助手", systemImage: "bubble.left.and.bubble.right")
            }
            .tag(Tab.assistant)

            NavigationStack {
                TasksView(model: model)
            }
            .badge(model.pendingDecisionCount)
            .tabItem {
                Label("任务", systemImage: "checklist")
            }
            .tag(Tab.tasks)

            NavigationStack {
                MemoryView(model: model)
            }
            .tabItem {
                Label("记忆", systemImage: "brain")
            }
            .tag(Tab.memory)

            NavigationStack {
                MeView(model: model)
            }
            .tabItem {
                Label("我的", systemImage: "person.crop.circle")
            }
            .tag(Tab.me)
        }
    }
}

// MARK: - 未配对 / 配对失败

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            PairingView(model: model)
        }
    }
}
