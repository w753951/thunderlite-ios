import SwiftUI

// MARK: - 底部导航

enum MainTab: Int, CaseIterable {
  case downloads, explore

  var title: String {
    switch self {
    case .downloads: return "下载"
    case .explore: return "探索"
    }
  }

  var symbol: String {
    switch self {
    case .downloads: return "arrow.down.circle"
    case .explore: return "antenna.radiowaves.left.and.right"
    }
  }

  var symbolFilled: String {
    switch self {
    case .downloads: return "arrow.down.circle.fill"
    case .explore: return "antenna.radiowaves.left.and.right"
    }
  }
}

/// 底部胶囊式 Tab 栏，和整体设计语言一致。
struct MainTabBar: View {
  @Binding var selection: MainTab
  /// 正在下载的任务数，显示在「下载」上。
  var activeDownloads: Int

  var body: some View {
    HStack(spacing: 0) {
      ForEach(MainTab.allCases, id: \.rawValue) { tab in
        Button { selection = tab } label: {
          HStack(spacing: 7) {
            Image(systemName: selection == tab ? tab.symbolFilled : tab.symbol)
              .font(.system(size: 16, weight: .semibold))

            if selection == tab {
              Text(tab.title)
                .font(.system(size: 12, weight: .bold))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if tab == .downloads && activeDownloads > 0 {
              Text("\(activeDownloads)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                  Capsule().fill(selection == tab
                                 ? Theme.bgDeep.opacity(0.25)
                                 : Theme.accent.opacity(0.2))
                )
            }
          }
          .foregroundColor(selection == tab ? Theme.bgDeep : Theme.textTertiary)
          .padding(.horizontal, selection == tab ? 16 : 12)
          .padding(.vertical, 10)
          .background(
            Group {
              if selection == tab {
                Capsule().fill(Theme.accentGradient)
              } else {
                Capsule().fill(Color.clear)
              }
            }
          )
        }
        .buttonStyle(.plain)

        if tab != MainTab.allCases.last {
          Spacer(minLength: 0)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      Capsule()
        .fill(Theme.bgElevated)
        .overlay(
          Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 6)
    )
    .padding(.horizontal, 44)
    .padding(.bottom, 6)
    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selection)
  }
}

// MARK: - 主容器

/// 根容器：下载页 / 探索页两个 Tab 共用底部导航。
struct MainContainerView: View {
  @EnvironmentObject private var engine: DownloadEngine
  @State private var selection: MainTab = .downloads

  private var activeDownloads: Int {
    engine.tasks.filter {
      $0.state == .downloading || $0.state == .waiting || $0.state == .probing
    }.count
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      // 内容区
      Group {
        switch selection {
        case .downloads:
          RootView()
        case .explore:
          ExploreView()
        }
      }
      // 给底部 Tab 让出空间
      .padding(.bottom, 62)

      MainTabBar(selection: $selection, activeDownloads: activeDownloads)
    }
  }
}
