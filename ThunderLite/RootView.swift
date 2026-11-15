import SwiftUI
import UIKit
import Combine

/// 主界面：输入链接 → 下载 → 看进度。
struct RootView: View {
  @EnvironmentObject private var engine: DownloadEngine
  @EnvironmentObject private var prefs: Prefs

  @State private var input = ""
  @State private var errorText: String?
  @State private var showingSettings = false
  @FocusState private var inputFocused: Bool

  /// 每秒对一次「该不该常亮」。KeepAwake.set 内部会先去重，代价可以忽略。
  private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        inputBar
        if let errorText {
          banner(errorText)
        }
        list
      }
      .background(Color(white: 0.07).ignoresSafeArea())
      .navigationTitle("下载器")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button { showingSettings = true } label: {
            Image(systemName: "gearshape")
          }
        }
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView().environmentObject(prefs)
      }
      .onReceive(ticker) { _ in syncKeepAwake() }
      .onAppear { syncKeepAwake() }
    }
    .navigationViewStyle(.stack)
  }

  // MARK: - 输入

  private var inputBar: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        TextField("粘贴链接（支持网盘直链）", text: $input)
          .font(.body)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .submitLabel(.go)
          .focused($inputFocused)
          .onSubmit { submit() }
          .padding(.horizontal, 14)
          .padding(.vertical, 13)
          .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        if input.isEmpty {
          Button {
            pasteFromClipboard()
          } label: {
            Image(systemName: "doc.on.clipboard")
              .font(.system(size: 22, weight: .medium))
              .frame(width: 46, height: 46)
              .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        } else {
          Button {
            submit()
          } label: {
            Image(systemName: "arrow.down.circle.fill")
              .font(.system(size: 26, weight: .semibold))
              .frame(width: 46, height: 46)
              .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        }
      }

      HStack(spacing: 6) {
        Button {
          DirOpener.open(prefs.saveDirectory())
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "folder")
              .font(.footnote)
            Text(prefs.saveDirectoryLabel())
              .font(.footnote)
              .lineLimit(1)
              .truncationMode(.middle)
            Image(systemName: "arrow.up.forward.app")
              .font(.caption.weight(.semibold))
          }
          .foregroundColor(Color(white: 0.58))
        }
        .buttonStyle(.plain)
        Spacer(minLength: 8)
        Text("\(prefs.threads) 线程")
          .font(.footnote.weight(.medium))
          .foregroundColor(Color.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  private func banner(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.subheadline)
      Text(text)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        errorText = nil
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
      }
    }
    .foregroundColor(Color.orange)
    .padding(12)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
  }

  // MARK: - 列表

  @ViewBuilder
  private var list: some View {
    if engine.tasks.isEmpty {
      emptyState
    } else {
      List {
        ForEach(engine.tasks) { task in
          TaskRow(task: task)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                engine.remove(task, deleteFile: false)
              } label: {
                Label("移除", systemImage: "trash")
              }
              Button {
                engine.remove(task, deleteFile: true)
              } label: {
                Label("删文件", systemImage: "trash.slash")
              }
              .tint(.red)
            }
        }
      }
      .listStyle(.plain)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 54, weight: .thin))
        .foregroundColor(Color(white: 0.35))
      Text("把链接粘到上面")
        .font(.headline)
        .foregroundColor(Color.secondary)
      Text("支持 HTTP/HTTPS 直链与 8 家网盘\n最多 32 线程分块下载")
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(white: 0.4))
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - 动作

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

/// 一条下载任务。
struct TaskRow: View {
  @ObservedObject var task: DownloadTask
  @EnvironmentObject private var engine: DownloadEngine

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(task.fileName.isEmpty ? "准备中…" : task.fileName)
            .font(.headline)
            .lineLimit(2)
          HStack(spacing: 6) {
            if let site = task.site {
              Text(site.name)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: site.color).opacity(0.22), in: Capsule())
                .foregroundColor(Color(hex: site.color))
            }
            Text(subtitle)
              .font(.subheadline)
              .foregroundColor(Color.secondary)
          }
        }
        Spacer(minLength: 0)
        control
      }

      if task.state == .downloading || task.state == .paused || task.state == .waiting {
        ProgressView(value: task.progress)
          .progressViewStyle(.linear)
          .tint(task.state == .paused ? Color.orange : Color.accentColor)
      }

      if let error = task.errorText, task.state == .failed {
        Text(error)
          .font(.footnote)
          .foregroundColor(Color.red.opacity(0.85))
          .lineLimit(3)
      }
    }
    .padding(13)
    .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var subtitle: String {
    switch task.state {
    case .probing: return "正在解析…"
    case .waiting: return "排队中"
    case .downloading:
      let got = ByteText.bytes(task.receivedBytes)
      let all = ByteText.bytes(task.totalBytes)
      return "\(got) / \(all) · \(Int(task.progress * 100))%"
    case .paused:
      return "已暂停 · \(Int(task.progress * 100))%"
    case .done:
      return "完成 · \(ByteText.bytes(task.totalBytes))"
    case .failed:
      return "失败"
    }
  }

  @ViewBuilder
  private var control: some View {
    switch task.state {
    case .downloading, .probing, .waiting:
      Button { engine.pause(task) } label: {
        Image(systemName: "pause.circle.fill").font(.system(size: 28))
      }
      .buttonStyle(.plain)
    case .paused, .failed:
      Button { engine.resume(task) } label: {
        Image(systemName: "play.circle.fill").font(.system(size: 28))
      }
      .buttonStyle(.plain)
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 28))
        .foregroundColor(Color.green)
    }
  }
}

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
