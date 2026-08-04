import SwiftUI

@main
struct IAgentMobileApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = MobileAppModel()

  var body: some Scene {
    WindowGroup {
      MobileRootView(model: model)
        .preferredColorScheme(.dark)
        .task {
          await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
          guard phase == .active else { return }
          Task { await model.refresh() }
        }
    }
  }
}
