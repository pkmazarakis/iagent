import SwiftUI

@main
struct IAgentMobileApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("iagent.welcome.completed.v1") private var hasCompletedWelcome = false
  @StateObject private var model = MobileAppModel()
  @State private var dismissedForcedWelcome = false

  private var arguments: [String] { ProcessInfo.processInfo.arguments }

  private var shouldShowWelcome: Bool {
    if arguments.contains("--show-welcome") {
      return !dismissedForcedWelcome
    }
    if arguments.contains("--ui-testing") {
      return false
    }
    return !hasCompletedWelcome
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        if shouldShowWelcome {
          MobileWelcomeView(action: completeWelcome)
            .transition(.opacity.combined(with: .scale(scale: 1.015)))
        } else {
          MobileRootView(model: model)
            .transition(.opacity)
            .task {
              await model.start()
            }
        }
      }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
          model.handleDeepLink(url)
        }
        .onChange(of: scenePhase) { _, phase in
          guard phase == .active, !shouldShowWelcome else { return }
          Task { await model.refresh() }
        }
    }
  }

  private func completeWelcome() {
    hasCompletedWelcome = true
    let animation = reduceMotion
      ? Animation.linear(duration: 0.12)
      : Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.52)
    withAnimation(animation) {
      dismissedForcedWelcome = true
    }
  }
}
