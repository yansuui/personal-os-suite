import SwiftUI

/// v2 聊天、可选目标能力与设备信息；旧任务、计划、记忆和审批仍未接入。
public struct RootView: View {
    @ObservedObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            if model.phase.isReady { MainTabView(model: model) }
            else { OnboardingView(model: model) }
        }
        .tint(POSTheme.accent)
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            Task { await model.setApplicationActive(phase == .active) }
        }
    }
}

struct MainTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { AssistantView(model: model) }
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }.tag(0)
            NavigationStack { GoalsView(model: model) }
                .tabItem { Label("目标", systemImage: "target") }.tag(1)
            NavigationStack { MeView(model: model) }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(2)
        }
        .onChange(of: model.selectedTab) { _, tab in
            model.setGoalsTabActive(tab == 1)
            if tab == 1 { Task { await model.refreshGoals() } }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var body: some View { NavigationStack { PairingView(model: model) } }
}
