import SwiftUI

/// v2 仅展示聊天与设备信息；任务、计划、记忆和审批尚未接入。
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
        TabView {
            NavigationStack { AssistantView(model: model) }
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { MeView(model: model) }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var body: some View { NavigationStack { PairingView(model: model) } }
}
