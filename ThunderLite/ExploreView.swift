import SwiftUI

// MARK: - 自由探索

/// 内置浏览器 + 资源嗅探面板。
struct ExploreView: View {
  @StateObject private var store = SnifferStore()
  @EnvironmentObject private var prefs: Prefs
  @ObservedObject private var adStore = AdBlockStore.shared

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
  @State private var parsing = false
  @State private var parseMessage: String?
  @State private var errorText: String?

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

        // 解析状态 / 错误提示
        if parsing {
          HStack(spacing: 8) {
            ProgressView().tint(Theme.accent).scaleEffect(0.7)
            Text(parseMessage ?? "正在解析…")
              .font(.system(size: 11))
              .foregroundColor(Theme.accent)
            Spacer()
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Theme.accent.opacity(0.09))
        } else if let msg = parseMessage {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 11))
            Text(msg)
              .font(.system(size: 11))
            Spacer()
            Button { parseMessage = nil } label: {
              Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
            }
          }
          .foregroundColor(Color(hex: 0x35E08A))
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Color(hex: 0x35E08A).opacity(0.09))
        }

        if let err = errorText {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 11))
            Text(err)
              .font(.system(size: 11))
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { errorText = nil } label: {
              Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
            }
          }
          .foregroundColor(Theme.accentWarm)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Theme.accentWarm.opacity(0.09))
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

      // 设备模拟
      Menu {
        Button {
          prefs.emulateDevice = "phone"
        } label: {
          Label("手机", systemImage: prefs.emulateDevice == "phone"
                ? "checkmark" : "iphone")
        }
        Button {
          prefs.emulateDevice = "tablet"
        } label: {
          Label("平板", systemImage: prefs.emulateDevice == "tablet"
                ? "checkmark" : "ipad")
        }
        Button {
          prefs.emulateDevice = "desktop"
        } label: {
          Label("桌面", systemImage: prefs.emulateDevice == "desktop"
                ? "checkmark" : "desktopcomputer")
        }
      } label: {
        Image(systemName: prefs.emulateDevice == "tablet" ? "ipad"
              : prefs.emulateDevice == "desktop" ? "desktopcomputer" : "iphone")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(prefs.emulateDevice == "phone" ? Theme.textSecondary : Theme.accent)
          .frame(width: 30, height: 30)
      }
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
                   command: $command,
                   adBlockEnabled: prefs.adBlockEnabled,
                   userAgent: prefs.emulatedUserAgent)
      .id(prefs.adBlockVersion)   // 规则重编译后重建 webview
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

        // 拦截计数
        if prefs.adBlockEnabled && adStore.blockedCount > 0 {
          HStack(spacing: 4) {
            Image(systemName: "shield.lefthalf.filled")
              .font(.system(size: 9))
            Text("\(adStore.blockedCount)")
              .font(.system(size: 9, weight: .bold, design: .rounded))
              .monospacedDigit()
          }
          .foregroundColor(Color(hex: 0x35E08A))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
        }

        // 一键最高画质
        if activeKind == .video, let best = store.bestVideo {
          Button { downloadBest(best) } label: {
            HStack(spacing: 4) {
              Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 9, weight: .bold))
              Text(best.quality.isEmpty ? "最高" : best.quality)
                .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(Theme.bgDeep)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.accentGradient))
          }
          .buttonStyle(.plain)
          .padding(.trailing, 4)
        }

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
            // 清晰度徽章
            if !item.quality.isEmpty && item.kind == .video {
              Text(item.quality)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(item.isHighQuality ? Theme.accentWarm : Theme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                  Capsule().fill(
                    item.isHighQuality
                      ? Theme.accentWarm.opacity(0.16)
                      : Color.white.opacity(0.08))
                )
            }
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

  /// 下载当前页面最高画质的那一条。
  private func downloadBest(_ item: SniffedMedia) {
    var headers: [String: String] = [:]
    if let host = item.url.host {
      if host.contains("bilibili") || host.contains("hdslb") {
        headers["Referer"] = "https://www.bilibili.com/"
      } else if host.contains("douyin") || host.contains("byteimg")
                  || host.contains("douyinvod") {
        headers["Referer"] = "https://www.douyin.com/"
      }
    }
    try? DownloadEngine.shared.add(url: item.url.absoluteString,
                                   saveTo: prefs.saveDirectory(),
                                   threads: prefs.threads,
                                   extraHeaders: headers)
  }

  private func open(_ raw: String) {
    guard let u = URL(string: raw) else { return }
    addressText = raw
    committedURL = u
    showingHome = false
    store.reset()
  }

  private func navigate() {
    let raw = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return }

    // 先用分享文本解析器抠链接：粘贴抖音/哔哩哔哩的整段分享文案时，
    // 直接拿这段文字去搜索是搜不出东西的，必须先提取真实 URL。
    if let found = ShareTextParser.extractURL(from: raw) {
      // 抖音 / B 站：直接解析出媒体，不走网页
      let site = VideoPageResolver.site(for: found)
      if site == .douyin || site == .bilibili {
        resolveAndDownload(from: raw, site: site)
        return
      }
      addressText = found.absoluteString
      committedURL = found
      showingHome = false
      store.reset()
      return
    }

    // 没有链接：纯文字搜索
    if let q = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
       let u = URL(string: "https://www.bing.com/search?q=" + q) {
      addressText = u.absoluteString
      committedURL = u
      showingHome = false
      store.reset()
    }
  }

  /// 地址栏里直接解析抖音 / B 站并加进下载队列。
  private func resolveAndDownload(from text: String,
                                  site: VideoPageResolver.Site) {
    parsing = true
    parseMessage = "正在解析\(site == .bilibili ? "哔哩哔哩" : "抖音")…"
    errorText = nil

    VideoPageResolver.resolve(from: text) { result in
      Task { @MainActor in
        parsing = false
        switch result {
        case .success(let bundle):
          var headers: [String: String] = [:]
          headers["Referer"] = site == .bilibili
            ? "https://www.bilibili.com/"
            : "https://www.douyin.com/"

          var added = 0
          for u in bundle.videos.prefix(4) {
            let kind: MediaKind = u.path.lowercased().hasSuffix(".m4a")
              || u.path.lowercased().hasSuffix(".mp3") ? .audio : .video
            var m = SniffedMedia(url: u, kind: kind)
            m.quality = kind == .audio ? "音轨" : "最高"
            store.ingestPreview(m)
            if (try? DownloadEngine.shared.add(url: u.absoluteString,
                                               saveTo: prefs.saveDirectory(),
                                               threads: prefs.threads,
                                               extraHeaders: headers)) != nil {
              added += 1
            }
          }
          for u in bundle.images.prefix(30) {
            let m = SniffedMedia(url: u, kind: .image)
            store.ingestPreview(m)
            if (try? DownloadEngine.shared.add(url: u.absoluteString,
                                               saveTo: prefs.saveDirectory(),
                                               threads: 8,
                                               extraHeaders: headers)) != nil {
              added += 1
            }
          }

          if added > 0 {
            parseMessage = "已加入 \(added) 个下载任务，可以在「下载」里看进度"
            // 把面板切到视频并展开，让解析结果立刻可见
            activeKind = bundle.videos.isEmpty ? .image : .video
            panelExpanded = true
            showingHome = false
            addressText = bundle.title
          } else {
            errorText = "解析到了内容但没能加入下载队列。"
          }
        case .failure(let err):
          errorText = (err as? LocalizedError)?.errorDescription
            ?? err.localizedDescription
          parseMessage = nil
        }
      }
    }
  }
}
