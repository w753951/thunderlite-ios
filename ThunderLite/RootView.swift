import SwiftUI
import UIKit

/// 主界面：输入链接 → 下载 → 看进度。
struct RootView: View {
  @EnvironmentObject private var engine: DownloadEngine
  @EnvironmentObject private var prefs: Prefs

  @State private var input = ""
  @State private var errorText: String?
  @State private var showingSettings = false
  @FocusState private var inputFocused: Bool

  var body: some View {
    NavigationStack {
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
        ToolbarItem(placement: .topBarTrailing) {
          Button { showingSettings = true } label: {
            Image(systemName: "gearshape")
          }
        }
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView().environmentObject(prefs)
      }
      .onChange(of: engine.tasks.count) { _, _ in syncKeepAwake() }
      .onAppear {
        PasteboardWatcher.start()
      }
    }
  }

  // MARK: - 输入

  private var inputBar: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        TextField("粘贴链接（支持网盘直链）", text: $input, axis: .vertical)
          .lineLimit(1...3)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .focused($inputFocused)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        if input.isEmpty {
          Button {
            pasteFromClipboard()
          } label: {
            Image(systemName: "doc.on.clipboard")
              .font(.system(size: 19, weight: .medium))
              .frame(width: 46, height: 46)
              .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        } else {
          Button {
            submit()
          } label: {
            Image(systemName: "arrow.down.circle.fill")
              .font(.system(size: 24, weight: .semibold))
              .frame(width: 46, height: 46)
              .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
        }
      }

      HStack(spacing: 6) {
        Image(systemName: "folder")
          .font(.system(size: 11))
        Text(prefs.saveDirectoryLabel())
          .font(.system(size: 11))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Text("\(prefs.threads) 线程")
          .font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  private func banner(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 13))
      Text(text)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        errorText = nil
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
      }
    }
    .foregroundStyle(.orange)
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
      .scrollContentBackground(.hidden)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 54, weight: .thin))
        .foregroundStyle(.tertiary)
      Text("把链接粘到上面")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
      Text("支持 HTTP/HTTPS 直链与 8 家网盘\n最多 32 线程分块下载")
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .foregroundStyle(.tertiary)
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
      try engine.add(url: text, saveTo: prefs.saveDirectory(), threads: prefs.threads)
      input = ""
      errorText = nil
      inputFocused = false
      syncKeepAwake()
    } catch {
      errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func syncKeepAwake() {
    let active = prefs.keepAwake && engine.tasks.contains {
      $0.state == .downloading || $0.state == .waiting || $0.state == .probing
    }
    KeepAwake.set(active)
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
            .font(.system(size: 14, weight: .medium))
            .lineLimit(2)
          HStack(spacing: 6) {
            if let site = task.site {
              Text(site.name)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(hex: site.color).opacity(0.22),
                            in: Capsule())
                .foregroundStyle(Color(hex: site.color))
            }
            Text(subtitle)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
        control
      }

      if task.state == .downloading || task.state == .paused || task.state == .waiting {
        ProgressView(value: task.progress)
          .progressViewStyle(.linear)
          .tint(task.state == .paused ? .orange : .accentColor)
      }

      if let error = task.errorText, task.state == .failed {
        Text(error)
          .font(.system(size: 11))
          .foregroundStyle(.red.opacity(0.85))
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
        Image(systemName: "pause.circle.fill").font(.system(size: 26))
      }
      .buttonStyle(.plain)
    case .paused, .failed:
      Button { engine.resume(task) } label: {
        Image(systemName: "play.circle.fill").font(.system(size: 26))
      }
      .buttonStyle(.plain)
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 26))
        .foregroundStyle(.green)
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

/// 只是让 App 回到前台时能刷新剪贴板状态；真正的粘贴按钮在自己按。
enum PasteboardWatcher {
  static func start() {}
}
