import SwiftUI

// MARK: - 自由探索

/// 内置浏览器 + 资源嗅探面板。
struct ExploreView: View {
  @StateObject private var store = SnifferStore()

  @State private var addressText = ""
  @State private var committedURL = URL(string: "about:blank")!
  @State private var progress: Double = 0
  @State private var pageTitle = ""
  @State private var canGoBack = false
  @State private var canGoForward = false
  @State private var command: BrowserCommand?

  @State private var showingHome = true
  @State private var activeKind: MediaKind = .video
  @State private var previewItem: SniffedMedia?
  @State private var panelExpanded = true

  var body: some View {
    ZStack {
      Theme.bgDeep.ignoresSafeArea()

      VStack(spacing: 0) {
        addressBar
        if progress > 0 && progress < 1 {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(Theme.accent)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
        }

        ZStack {
          browser

          if showingHome {
            homePanel
              .transition(.opacity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if !showingHome {
          mediaPanel
        }
      }
    }
    .animation(.easeInOut(duration: 0.22), value: showingHome)
    .animation(.easeInOut(duration: 0.22), value: panelExpanded)
    .sheet(item: $previewItem) { item in
      MediaPreviewSheet(media: item)
    }
  }

  // MARK: 地址栏

  private var addressBar: some View {
    HStack(spacing: 8) {
      // 返回
      Button { command = .back } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(canGoBack ? Theme.textPrimary : Theme.textTertiary)
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
      .disabled(!canGoBack)

      // 地址输入
      HStack(spacing: 7) {
        Image(systemName: committedURL.scheme == "https" ? "lock.fill" : "globe")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(Theme.textTertiary)

        TextField("", text: $addressText)
          .font(.system(size: 13))
          .foregroundColor(Theme.textPrimary)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .submitLabel(.go)
          .onSubmit { navigate() }
          .accentColor(Theme.accent)
          .overlay(
            Group {
              if addressText.isEmpty {
                Text("输入网址或搜索")
                  .font(.system(size: 13))
                  .foregroundColor(Theme.textTertiary)
              }
            },
            alignment: .leading
          )

        if progress > 0 && progress < 1 {
          Button { command = .stop } label: {
            Image(systemName: "xmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(Theme.textTertiary)
          }
          .buttonStyle(.plain)
        } else if !addressText.isEmpty {
          Button { navigate() } label: {
            Image(systemName: "arrow.right")
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(Theme.accent)
          }
          .buttonStyle(.plain)
        } else {
          Button { command = .reload } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(Theme.textTertiary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(Color.white.opacity(0.055))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
      )

      // 回首页
      Button {
        showingHome = true
        store.reset()
      } label: {
        Image(systemName: "square.grid.2x2")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(showingHome ? Theme.accent : Theme.textSecondary)
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .background(Theme.bgElevated.opacity(0.9))
  }

  // MARK: 浏览器

  private var browser: some View {
    SnifferWebView(store: store,
                   url: committedURL,
                   progress: $progress,
                   pageTitle: $pageTitle,
                   canGoBack: $canGoBack,
                   canGoForward: $canGoForward,
                   command: $command)
      .opacity(showingHome ? 0 : 1)
      .allowsHitTesting(!showingHome)
  }

  // MARK: 首页

  private var homePanel: some View {
    ScrollView {
      VStack(spacing: 24) {
        VStack(spacing: 8) {
          ZStack {
            Circle()
              .fill(Theme.accent.opacity(0.07))
              .frame(width: 110, height: 110)
              .blur(radius: 18)
            Image(systemName: "antenna.radiowaves.left.and.right")
              .font(.system(size: 30, weight: .light))
              .foregroundColor(Theme.accent)
          }
          .padding(.bottom, 4)

          Text("从网络抓取资源")
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundColor(Theme.textPrimary)

          Text("打开视频网站 · 自动识别视频与图片")
            .font(.system(size: 12))
            .foregroundColor(Theme.textTertiary)
        }
        .padding(.top, 32)

        // 快捷站点
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 20) {
          ForEach(SniffHome.sites) { site in
            Button { open(site.url) } label: {
              VStack(spacing: 8) {
                ZStack {
                  RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                      LinearGradient(
                        colors: [Color(hex: site.tint).opacity(0.9),
                                 Color(hex: site.tint).opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 62, height: 62)
                    .shadow(color: Color(hex: site.tint).opacity(0.35), radius: 10, x: 0, y: 4)

                  Text(String(site.name.prefix(1)))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                }
                Text(site.name)
                  .font(.system(size: 10, weight: .medium))
                  .foregroundColor(Theme.textSecondary)
                  .lineLimit(1)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 24)

        // 提示
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "info.circle")
            .font(.system(size: 11))
          Text("在网页里播放视频或浏览图片后，底部会自动出现可下载的资源列表。点击即可预览和下载。")
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Theme.textTertiary)
        .padding(13)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.035))
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
      }
    }
    .background(Theme.bgDeep)
  }

  // MARK: 资源面板

  private var mediaPanel: some View {
    VStack(spacing: 0) {
      // 分隔线
      Rectangle()
        .fill(Color.white.opacity(0.07))
        .frame(height: 1)

      // 头部：分类标签 + 折叠
      HStack(spacing: 0) {
        ForEach(MediaKind.allCases, id: \.self) { kind in
          let n = store.count(of: kind)
          Button {
            activeKind = kind
            if !panelExpanded { panelExpanded = true }
          } label: {
            HStack(spacing: 5) {
              Text(kind.title)
                .font(.system(size: 12,
                              weight: activeKind == kind ? .bold : .medium))
              if n > 0 {
                Text("\(n)")
                  .font(.system(size: 9, weight: .bold, design: .rounded))
                  .monospacedDigit()
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(
                    Capsule().fill(activeKind == kind
                                   ? Theme.accent.opacity(0.22)
                                   : Color.white.opacity(0.08))
                  )
              }
            }
            .foregroundColor(activeKind == kind ? Theme.accent : Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
        }

        Spacer()

        Button { panelExpanded.toggle() } label: {
          Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.textTertiary)
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 10)
      .background(Theme.bgElevated)

      if panelExpanded {
        let list = store.items(of: activeKind)
        if list.isEmpty {
          HStack(spacing: 8) {
            ProgressView().tint(Theme.accent).scaleEffect(0.7)
            Text("正在监听\(activeKind.title)请求…")
              .font(.system(size: 11))
              .foregroundColor(Theme.textTertiary)
            Spacer()
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 18)
          .background(Theme.bgElevated)
        } else {
          ScrollView {
            LazyVStack(spacing: 6) {
              ForEach(list) { item in
                mediaRow(item)
              }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
          }
          .frame(maxHeight: 210)
          .background(Theme.bgElevated)
        }
      }
    }
  }

  private func mediaRow(_ item: SniffedMedia) -> some View {
    Button { previewItem = item } label: {
      HStack(spacing: 10) {
        // 缩略图
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.05))
          if item.kind == .image {
            AsyncImage(url: item.url) { phase in
              if case .success(let img) = phase {
                img.resizable().scaledToFill()
              } else {
                Image(systemName: item.kind.symbol)
                  .font(.system(size: 13))
                  .foregroundColor(Theme.textTertiary)
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          } else {
            Image(systemName: item.kind.symbol)
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(Theme.accent.opacity(0.8))
          }
        }
        .frame(width: 46, height: 34)

        VStack(alignment: .leading, spacing: 2) {
          Text(item.suggestedName)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          HStack(spacing: 5) {
            if let s = item.pixelSize {
              Text(s)
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(Theme.textTertiary)
            }
            Text(item.url.host ?? "")
              .font(.system(size: 9))
              .foregroundColor(Theme.textTertiary.opacity(0.8))
              .lineLimit(1)
            if item.isManifest {
              Text("HLS")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.accentWarm)
            }
          }
        }

        Spacer(minLength: 4)

        Image(systemName: "play.circle.fill")
          .font(.system(size: 20))
          .foregroundColor(Theme.accent.opacity(0.85))
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.white.opacity(0.03))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: 动作

  private func open(_ raw: String) {
    guard let u = URL(string: raw) else { return }
    addressText = raw
    committedURL = u
    showingHome = false
    store.reset()
  }

  private func navigate() {
    var text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // 没写协议就补上；看着不像域名就走必应搜索
    if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
      if text.contains(".") && !text.contains(" ") {
        text = "https://" + text
      } else if let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                let u = URL(string: "https://www.bing.com/search?q=" + q) {
        committedURL = u
        showingHome = false
        store.reset()
        return
      } else {
        return
      }
    }

    guard let u = URL(string: text) else { return }
    committedURL = u
    showingHome = false
    store.reset()
  }
}
