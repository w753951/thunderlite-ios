import SwiftUI
import UIKit
import Combine

// MARK: - 设计系统

/// 全局视觉规范。集中在这里，改主题只动这一处。
enum Theme {
  // 背景：近黑带一点蓝，比纯黑更有层次
  static let bgDeep = Color(hex: 0x05070C)
  static let bgElevated = Color(hex: 0x0B0F17)

  // 卡片：半透明玻璃，配描边
  static let cardTop = Color(hex: 0x151B26)
  static let cardBottom = Color(hex: 0x0D121B)
  static let strokeTop = Color.white.opacity(0.10)
  static let strokeBottom = Color.white.opacity(0.03)

  // 强调色：青蓝 → 紫，科技感
  static let accent = Color(hex: 0x38E1FF)
  static let accentAlt = Color(hex: 0x7B6BFF)
  static let accentWarm = Color(hex: 0xFFB340)

  // 文字
  static let textPrimary = Color(hex: 0xEEF3FA)
  static let textSecondary = Color(hex: 0x8A96AB)
  static let textTertiary = Color(hex: 0x5A6478)

  static var accentGradient: LinearGradient {
    LinearGradient(colors: [accent, accentAlt],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
  }
  static var cardGradient: LinearGradient {
    LinearGradient(colors: [cardTop, cardBottom],
                   startPoint: .top, endPoint: .bottom)
  }
}

/// 背景：两层径向光晕 + 细网格，制造纵深。
struct AuroraBackground: View {
  var body: some View {
    ZStack {
      Theme.bgDeep

      // 左上角青光
      RadialGradient(
        colors: [Theme.accent.opacity(0.22), .clear],
        center: .init(x: 0.12, y: 0.02),
        startRadius: 0, endRadius: 420)

      // 右下角紫光
      RadialGradient(
        colors: [Theme.accentAlt.opacity(0.20), .clear],
        center: .init(x: 0.95, y: 0.55),
        startRadius: 0, endRadius: 460)

      // 底部微光
      RadialGradient(
        colors: [Theme.accent.opacity(0.07), .clear],
        center: .init(x: 0.5, y: 1.02),
        startRadius: 0, endRadius: 340)
    }
    .ignoresSafeArea()
  }
}

/// 玻璃卡片背景：渐变填充 + 内外描边 + 柔和投影。
struct GlassCard: ViewModifier {
  var radius: CGFloat = 18
  var glow: Color? = nil

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(Theme.cardGradient)
      )
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(
            LinearGradient(colors: [Theme.strokeTop, Theme.strokeBottom],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 1)
      )
      .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.35 : 0.28),
              radius: glow == nil ? 12 : 16, x: 0, y: 5)
  }
}

extension View {
  func glassCard(radius: CGFloat = 18, glow: Color? = nil) -> some View {
    modifier(GlassCard(radius: radius, glow: glow))
  }
}

// MARK: - 主界面

/// 主界面：输入链接 → 下载 → 看进度。
struct RootView: View {
  @EnvironmentObject private var engine: DownloadEngine


  @State private var input = ""
  @State private var errorText: String?
  @State private var showingSettings = false
  @FocusState private var inputFocused: Bool

  /// 每秒对一次「该不该常亮」。
  private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  /// 全速合计：所有在下载的任务速度之和，显示在顶部。
  private var totalSpeed: Double {
    engine.tasks
      .filter { $0.state == .downloading }
      .reduce(0) { $0 + $1.bytesPerSecond }
  }

  private var activeCount: Int {
    engine.tasks.filter { $0.state == .downloading }.count
  }

  var body: some View {
    ZStack {
      AuroraBackground()

      VStack(spacing: 0) {
        header
        inputBar
        if let errorText { banner(errorText) }
        list
      }
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showingSettings) {
      SettingsView().environmentObject(prefs)
    }
    .onReceive(ticker) { _ in
      syncKeepAwake()
      for task in engine.tasks { task.tickSpeed() }
    }
    .onAppear { syncKeepAwake() }
  }

  // MARK: 顶部标题栏

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          // 品牌点：有任务时呼吸
          Circle()
            .fill(Theme.accentGradient)
            .frame(width: 7, height: 7)
            .overlay(
              Circle()
                .stroke(Theme.accent.opacity(0.55), lineWidth: 1)
                .scaleEffect(activeCount > 0 ? 2.4 : 1)
                .opacity(activeCount > 0 ? 0 : 1)
            )

          Text("THUNDERLITE")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(3.2)
            .foregroundColor(Theme.textTertiary)
        }

        Text("下载器")
          .font(.system(size: 27, weight: .bold, design: .rounded))
          .foregroundColor(Theme.textPrimary)
      }

      Spacer(minLength: 0)

      // 速度概览
      if activeCount > 0 {
        VStack(alignment: .trailing, spacing: 1) {
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(ByteText.valueOnly(totalSpeed))
              .font(.system(size: 17, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .foregroundColor(Theme.accent)
            Text(ByteText.unitOnly(totalSpeed))
              .font(.system(size: 10, weight: .medium, design: .rounded))
              .foregroundColor(Theme.textTertiary)
          }
          Text("\(activeCount) 个任务")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Theme.textTertiary)
        }
      }

      Button { showingSettings = true } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(Theme.textSecondary)
          .frame(width: 38, height: 38)
          .background(
            Circle().fill(Color.white.opacity(0.06))
          )
          .overlay(
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 18)
  }

  // MARK: 输入区

  private var inputBar: some View {
    VStack(spacing: 12) {
      HStack(spacing: 10) {
        HStack(spacing: 9) {
          Image(systemName: "link")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(inputFocused ? Theme.accent : Theme.textTertiary)

          TextField("", text: $input)
            .font(.system(size: 15))
            .foregroundColor(Theme.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .focused($inputFocused)
            .onSubmit { submit() }
            .overlay(
              // 自定义占位符（系统 placeholder 在这套配色下发灰不好看）
              Group {
                if input.isEmpty {
                  Text("粘贴下载链接")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textTertiary)
                }
              },
              alignment: .leading
            )
            .accentColor(Theme.accent)

          if !input.isEmpty {
            Button { input = "" } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.textTertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.045))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
              inputFocused
                ? Theme.accent.opacity(0.5)
                : Color.white.opacity(0.07),
              lineWidth: 1)
        )

        actionButton
      }

      // 目录 + 线程
      HStack(spacing: 8) {
        Button { DirOpener.open(prefs.saveDirectory()) } label: {
          HStack(spacing: 5) {
            Image(systemName: "folder.fill")
              .font(.system(size: 10))
            Text(prefs.saveDirectoryLabel())
              .font(.system(size: 11, weight: .medium))
              .lineLimit(1)
              .truncationMode(.middle)
            Image(systemName: "arrow.up.forward")
              .font(.system(size: 8, weight: .bold))
          }
          .foregroundColor(Theme.textSecondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            Capsule().fill(Color.white.opacity(0.04))
          )
          .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
          )
        }
        .buttonStyle(.plain)

        Spacer(minLength: 4)

        HStack(spacing: 4) {
          ForEach(0..<3) { i in
            Capsule()
              .fill(threadColor(i))
              .frame(width: 3, height: 8 + CGFloat(i) * 2)
          }
          Text("\(prefs.threads)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(Theme.textSecondary)
          Text("线程")
            .font(.system(size: 10))
            .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
      }
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 16)
  }

  private func threadColor(_ i: Int) -> Color {
    let t = Double(prefs.threads) / 32.0
    return i == 0 ? Theme.accent.opacity(0.9)
         : i == 1 ? Theme.accent.opacity(0.4 + t * 0.4)
         : Theme.accentAlt.opacity(0.3 + t * 0.5)
  }

  @ViewBuilder
  private var actionButton: some View {
    let isPaste = input.isEmpty
    Button {
      isPaste ? pasteFromClipboard() : submit()
    } label: {
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isPaste ? AnyShapeStyle(Color.white.opacity(0.06))
                        : AnyShapeStyle(Theme.accentGradient))
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(
            isPaste ? Color.white.opacity(0.08) : Color.white.opacity(0.22),
            lineWidth: 1)

        Image(systemName: isPaste ? "doc.on.clipboard" : "arrow.down")
          .font(.system(size: 17, weight: .bold))
          .foregroundColor(isPaste ? Theme.textSecondary : Theme.bgDeep)
      }
      .frame(width: 48, height: 48)
      .shadow(color: isPaste ? .clear : Theme.accent.opacity(0.35),
              radius: 12, x: 0, y: 4)
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.15), value: isPaste)
  }

  // MARK: 错误条

  private func banner(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 12))
        .padding(.top, 1)
      Text(text)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button { errorText = nil } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
      }
    }
    .foregroundColor(Theme.accentWarm)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Theme.accentWarm.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Theme.accentWarm.opacity(0.22), lineWidth: 1)
    )
    .padding(.horizontal, 20)
    .padding(.bottom, 12)
  }

  // MARK: 列表

  @ViewBuilder
  private var list: some View {
    if engine.tasks.isEmpty {
      emptyState
    } else {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach(engine.tasks) { task in
            TaskRow(task: task)
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 0) {
      Spacer()

      ZStack {
        Circle()
          .fill(Theme.accent.opacity(0.06))
          .frame(width: 132, height: 132)
          .blur(radius: 22)

        Circle()
          .strokeBorder(
            LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accentAlt.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1)
          .frame(width: 96, height: 96)

        Image(systemName: "arrow.down")
          .font(.system(size: 34, weight: .light))
          .foregroundStyle(Theme.accentGradient)
      }
      .padding(.bottom, 22)

      Text("等待下载")
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundColor(Theme.textPrimary)
        .padding(.bottom, 6)

      Text("粘贴 HTTP/HTTPS 直链或网盘链接")
        .font(.system(size: 12))
        .foregroundColor(Theme.textTertiary)
        .padding(.bottom, 3)

      Text("32 线程分块 · 断点续传 · 8 家网盘")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Theme.textTertiary.opacity(0.7))

      Spacer()
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: 动作

  private func pasteFromClipboard() {
    if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      input = text
    } else {
      errorText = "剪贴板里没有文字。"
    }
  }

  private func submit() {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    do {
      let site = NetdiskSupport.site(for: text)
      let cookie = site.map { prefs.cookie(for: $0.key) } ?? nil
      let force = site.map { prefs.isCookieForced(for: $0.key) } ?? false
      try engine.add(url: text, saveTo: prefs.saveDirectory(),
                     threads: prefs.threads, cookie: cookie, forceCookie: force)
      input = ""
      errorText = nil
      inputFocused = false
      syncKeepAwake()
    } catch {
      errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func syncKeepAwake() {
    KeepAwake.set(prefs.keepAwake && engine.hasActiveTask)
  }
}

// MARK: - 任务卡片

/// 一条下载任务。
struct TaskRow: View {
  @ObservedObject var task: DownloadTask
  @EnvironmentObject private var engine: DownloadEngine

  private var accentForState: Color {
    switch task.state {
    case .downloading: return Theme.accent
    case .paused: return Theme.accentWarm
    case .done: return Color(hex: 0x35E08A)
    case .failed: return Color(hex: 0xFF5E6E)
    default: return Theme.textTertiary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 11) {
        // 左侧状态条
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(
            LinearGradient(colors: [accentForState, accentForState.opacity(0.25)],
                           startPoint: .top, endPoint: .bottom)
          )
          .frame(width: 3)
          .frame(maxHeight: .infinity)

        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .top, spacing: 8) {
            Text(task.fileName.isEmpty ? "准备中…" : task.fileName)
              .font(.system(size: 14, weight: .semibold))
              .foregroundColor(Theme.textPrimary)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            control
          }

          HStack(spacing: 6) {
            if let site = task.site {
              Text(site.name)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                  Capsule().fill(Color(hex: site.color).opacity(0.16))
                )
                .overlay(
                  Capsule().strokeBorder(Color(hex: site.color).opacity(0.32), lineWidth: 1)
                )
                .foregroundColor(Color(hex: site.color))
            }
            Text(stateLabel)
              .font(.system(size: 10, weight: .medium))
              .foregroundColor(accentForState.opacity(0.9))
            Spacer(minLength: 0)
          }
        }
      }

      // 进度区
      if task.state != .failed {
        VStack(spacing: 8) {
          // 自定义进度条
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.white.opacity(0.07))
              Capsule()
                .fill(
                  LinearGradient(
                    colors: task.state == .done
                      ? [Color(hex: 0x35E08A), Color(hex: 0x2BB673)]
                      : [accentForState, Theme.accentAlt],
                    startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: max(0, geo.size.width * CGFloat(task.progress)))
                .shadow(color: accentForState.opacity(0.5), radius: 6, x: 0, y: 0)
            }
          }
          .frame(height: 5)

          HStack(alignment: .firstTextBaseline, spacing: 0) {
            // 大号速度
            if task.state == .downloading || task.state == .paused {
              HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(task.speedValue)
                  .font(.system(size: 23, weight: .bold, design: .rounded))
                  .monospacedDigit()
                  .foregroundColor(accentForState)
                Text(task.speedUnit)
                  .font(.system(size: 11, weight: .semibold, design: .rounded))
                  .foregroundColor(Theme.textTertiary)
              }
            } else {
              Text(ByteText.bytes(task.totalBytes))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
              if let left = task.remainingLabel, task.state == .downloading {
                Text(left)
                  .font(.system(size: 10, weight: .medium))
                  .foregroundColor(Theme.textSecondary)
              }
              Text(transferredLabel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Theme.textTertiary)
            }
          }
        }
      }

      if let error = task.errorText, task.state == .failed {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10))
          Text(error)
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(Color(hex: 0xFF5E6E).opacity(0.9))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(hex: 0xFF5E6E).opacity(0.09))
        )
      }
    }
    .padding(14)
    .glassCard(radius: 16, glow: task.state == .downloading ? accentForState : nil)
    .contextMenu {
      Button {
        UIPasteboard.general.string = task.url.absoluteString
      } label: {
        Label("复制链接", systemImage: "link")
      }
      Button(role: .destructive) {
        engine.remove(task, deleteFile: false)
      } label: {
        Label("移除任务", systemImage: "trash")
      }
      Button(role: .destructive) {
        engine.remove(task, deleteFile: true)
      } label: {
        Label("移除并删除文件", systemImage: "trash.slash")
      }
    }
  }

  private var stateLabel: String {
    switch task.state {
    case .probing: return "解析中"
    case .waiting: return "排队中"
    case .downloading: return "\(Int(task.progress * 100))%"
    case .paused: return "已暂停"
    case .done: return "已完成"
    case .failed: return "失败"
    }
  }

  private var transferredLabel: String {
    let got = ByteText.bytes(task.receivedBytes)
    let all = ByteText.bytes(task.totalBytes)
    return "\(got) / \(all)"
  }

  @ViewBuilder
  private var control: some View {
    switch task.state {
    case .downloading, .probing, .waiting:
      Button { engine.pause(task) } label: {
        Image(systemName: "pause.fill")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(Theme.textSecondary)
          .frame(width: 30, height: 30)
          .background(Circle().fill(Color.white.opacity(0.07)))
          .overlay(Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
      }
      .buttonStyle(.plain)

    case .paused, .failed:
      Button { engine.resume(task) } label: {
        Image(systemName: "play.fill")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(Theme.bgDeep)
          .frame(width: 30, height: 30)
          .background(Circle().fill(accentForState))
          .shadow(color: accentForState.opacity(0.4), radius: 8, x: 0, y: 2)
      }
      .buttonStyle(.plain)

    case .done:
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundColor(Color(hex: 0x35E08A))
        .frame(width: 30, height: 30)
        .background(Circle().fill(Color(hex: 0x35E08A).opacity(0.13)))
        .overlay(Circle().strokeBorder(Color(hex: 0x35E08A).opacity(0.3), lineWidth: 1))
    }
  }
}

// MARK: - 颜色工具

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}

/// 点目录跳到 Filza 里看。
///
/// Filza 的 URL 形式在社区里有两种写法，设备上装的是哪个版本我们没法预判，
/// 所以按顺序试：`filza://view/<路径>` → `filza:///<路径>` → 只唤起 Filza；
/// 一个都没成功（没装 Filza）就退回「文件」App 的本 App 目录。
/// 判定标准是 `open` 的 success 回调，不是猜。
enum DirOpener {
  static func open(_ dir: URL) {
    let path = dir.path
    // 只转义空格一类字符，保留分隔符，Filza 才能按层级解析。
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path

    var candidates: [URL] = []
    for raw in ["filza://view\(encoded)", "filza://\(encoded)", "filza://", "shareddocuments://\(encoded)"] {
      if let url = URL(string: raw), !candidates.contains(url) {
        candidates.append(url)
      }
    }
    attempt(candidates)
  }

  private static func attempt(_ urls: [URL]) {
    guard let next = urls.first else { return }
    let rest = Array(urls.dropFirst())
    UIApplication.shared.open(next, options: [:]) { ok in
      if !ok { attempt(rest) }
    }
  }
}
