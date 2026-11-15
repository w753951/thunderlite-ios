import SwiftUI
import UIKit

@main
struct ThunderLiteApp: App {
  @StateObject private var engine = DownloadEngine.shared
  @StateObject private var prefs = Prefs.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ThunderLiteRoot()
        .environmentObject(engine)
        .environmentObject(prefs)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
          switch phase {
          case .active:
            // 回到前台：按当前是否有任务重新评估常亮。
            KeepAwake.set(prefs.keepAwake && engine.hasActiveTask)
          case .inactive, .background:
            // 离开前台一定恢复系统默认，不白耗电。
            KeepAwake.set(false)
          @unknown default:
            KeepAwake.set(false)
          }
        }
    }
  }
}

/// 全局根视图。单独抽出来，方便以后加引导页或状态注入。
struct ThunderLiteRoot: View {
  var body: some View {
    RootView()
  }
}
