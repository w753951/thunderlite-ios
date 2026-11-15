import SwiftUI

// MARK: - 任务设置

/// 下载任务的全局策略：并行度、自动选择、自动转码、自动转存。
struct TaskSettingsView: View {
  @EnvironmentObject private var prefs: Prefs
  @Environment(\.dismiss) private var dismiss

  @State private var showParallel = false
  @State private var showAutoSelect = false
  @State private var showTranscode = false

  var body: some View {
    ZStack {
      AuroraBackground()

      ScrollView {
        VStack(spacing: 22) {
          parallelSection
          autoSelectSection
          transcodeSection
          postProcessSection
          advancedSection
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 40)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { topBar }
  }

  // MARK: 顶栏

  private var topBar: some View {
    HStack {
      Button { dismiss() } label: {
        HStack(spacing: 3) {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .bold))
          Text("返回")
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(Theme.accent)
      }
      .buttonStyle(.plain)

      Spacer()

      Text("任务设置")
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundColor(Theme.textPrimary)

      Spacer()

      Button { resetDefaults() } label: {
        Text("恢复默认")
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(Theme.accent)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 14)
    .background(
      Theme.bgDeep.opacity(0.72)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(edges: .top)
    )
  }

  // MARK: 并行

  private var parallelSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      sectionLabel("并行")

      VStack(spacing: 0) {
        Button { withAnimation { showParallel.toggle() } } label: {
          HStack(spacing: 12) {
            Image(systemName: "pause.fill")
              .font(.system(size: 15, weight: .bold))
              .foregroundColor(Theme.accent)
              .frame(width: 26)

            Text("并行")
              .font(.system(size: 15, weight: .medium))
              .foregroundColor(Theme.textPrimary)

            Spacer()

            Text(prefs.maxConcurrentTasks == 0 ? "Max" : "\(prefs.maxConcurrentTasks)")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundColor(Theme.textSecondary)
              .padding(.horizontal, 9)
              .padding(.vertical, 4)
              .background(Capsule().fill(Color.white.opacity(0.07)))

            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .bold))
              .foregroundColor(Theme.textTertiary)
          }
          .padding(15)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showParallel {
          divider
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("同时下载任务数")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
              Spacer()
              Text(prefs.maxConcurrentTasks == 0
                   ? "Max（\(engineRunningCount) 个运行中）"
                   : "\(prefs.maxConcurrentTasks) 个")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.accent)
            }

            Slider(
              value: Binding(
                get: { Double(prefs.maxConcurrentTasks == 0 ? 8 : prefs.maxConcurrentTasks) },
                set: { prefs.maxConcurrentTasks = Int($0.rounded()) }
              ),
              in: 1...8,
              step: 1
            )
            .accentColor(Theme.accent)

            Toggle(isOn: Binding(
              get: { prefs.maxConcurrentTasks == 0 },
              set: { prefs.maxConcurrentTasks = $0 ? 0 : 3 }
            )) {
              Text("不限制（Max）")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            }
            .tint(Theme.accent)

            Text("任务之间是并行的，每个任务内部再按「线程数」分块。两者相乘太大时会被 CDN 限速。")
              .font(.system(size: 10))
              .foregroundColor(Theme.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(15)
        }
      }
      .glassCard(radius: 16)
    }
  }

  private var engineRunningCount: Int {
    DownloadEngine.shared.tasks.filter { $0.state == .downloading }.count
  }

  // MARK: 自动选择

  private var autoSelectSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      sectionLabel("自动选择")

      VStack(spacing: 0) {
        Button { withAnimation { showAutoSelect.toggle() } } label: {
          HStack(spacing: 12) {
            ZStack {
              Image(systemName: "cursorarrow.click")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.accent)
              Text("A")
                .font(.system(size: 8, weight: .black, design: .rounded))
                .foregroundColor(Theme.accent)
                .padding(2)
                .background(Circle().fill(Theme.bgDeep))
                .offset(x: 7, y: -7)
            }
            .frame(width: 26)

            Text("自动选择")
              .font(.system(size: 15, weight: .medium))
              .foregroundColor(Theme.textPrimary)

            Spacer()

            HStack(spacing: 4) {
              if prefs.autoSelectEnabled {
                miniChip("视频(\(prefs.autoSelectVideoHeight)P)")
              }
              if prefs.autoSelectAudio { miniChip("音频") }
              if prefs.autoSelectImage { miniChip("图片") }
            }

            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .bold))
              .foregroundColor(Theme.textTertiary)
          }
          .padding(15)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showAutoSelect {
          divider

          VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $prefs.autoSelectEnabled) {
              VStack(alignment: .leading, spacing: 2) {
                Text("启用自动选择")
                  .font(.system(size: 13, weight: .medium))
                  .foregroundColor(Theme.textPrimary)
                Text("批量任务里自动挑出需要的媒体")
                  .font(.system(size: 10))
                  .foregroundColor(Theme.textTertiary)
              }
            }
            .tint(Theme.accent)

            if prefs.autoSelectEnabled {
              VStack(alignment: .leading, spacing: 8) {
                Text("视频清晰度上限")
                  .font(.system(size: 12))
                  .foregroundColor(Theme.textSecondary)

                HStack(spacing: 6) {
                  ForEach([720, 1080, 1440, 2160], id: \.self) { h in
                    Button { prefs.autoSelectVideoHeight = h } label: {
                      Text("\(h)P")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(prefs.autoSelectVideoHeight == h
                                         ? Theme.bgDeep : Theme.textSecondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                          Group {
                            if prefs.autoSelectVideoHeight == h {
                              Capsule().fill(Theme.accentGradient)
                            } else {
                              Capsule().fill(Color.white.opacity(0.06))
                            }
                          }
                        )
                    }
                    .buttonStyle(.plain)
                  }
                }
              }

              Toggle(isOn: $prefs.autoSelectAudio) {
                Text("包含音频")
                  .font(.system(size: 13))
                  .foregroundColor(Theme.textPrimary)
              }
              .tint(Theme.accent)

              Toggle(isOn: $prefs.autoSelectImage) {
                Text("包含图片")
                  .font(.system(size: 13))
                  .foregroundColor(Theme.textPrimary)
              }
              .tint(Theme.accent)
            }
          }
          .padding(15)
        }
      }
      .glassCard(radius: 16)

      Text("当执行批量下载任务时，使用自动选择将帮助你自动选择需要的媒体类型及格式。")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.8))
        .padding(.leading, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: 自动转码

  private var transcodeSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      sectionLabel("自动转码")

      VStack(spacing: 0) {
        Button { withAnimation { showTranscode.toggle() } } label: {
          HStack(spacing: 12) {
            ZStack {
              Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.accent)
              Text("01")
                .font(.system(size: 7, weight: .black, design: .rounded))
                .foregroundColor(Theme.bgDeep)
                .offset(x: 8, y: -7)
            }
            .frame(width: 26)

            Text("自动转码")
              .font(.system(size: 15, weight: .medium))
              .foregroundColor(Theme.textPrimary)

            Spacer()

            HStack(spacing: 4) {
              if prefs.transcodeVideo { miniChip("视频") }
              if prefs.transcodeAudio { miniChip("音频") }
              if !prefs.transcodeVideo && !prefs.transcodeAudio { miniChip("关") }
            }

            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .bold))
              .foregroundColor(Theme.textTertiary)
          }
          .padding(15)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showTranscode {
          divider
          VStack(alignment: .leading, spacing: 13) {
            Toggle(isOn: $prefs.transcodeVideo) {
              VStack(alignment: .leading, spacing: 2) {
                Text("视频转 mp4")
                  .font(.system(size: 13, weight: .medium))
                  .foregroundColor(Theme.textPrimary)
                Text("ts / flv / mkv / webm → H.264 mp4")
                  .font(.system(size: 10))
                  .foregroundColor(Theme.textTertiary)
              }
            }
            .tint(Theme.accent)

            Toggle(isOn: $prefs.transcodeAudio) {
              VStack(alignment: .leading, spacing: 2) {
                Text("音频转 m4a")
                  .font(.system(size: 13, weight: .medium))
                  .foregroundColor(Theme.textPrimary)
                Text("flac / wav / ogg → AAC m4a")
                  .font(.system(size: 10))
                  .foregroundColor(Theme.textTertiary)
              }
            }
            .tint(Theme.accent)

            Text("转码在下载完成后由 AVFoundation 执行，会多花一些时间，但能保证系统相册和播放器都能直接打开。")
              .font(.system(size: 10))
              .foregroundColor(Theme.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(15)
        }
      }
      .glassCard(radius: 16)
    }
  }

  // MARK: 后处理

  private var postProcessSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      sectionLabel("后处理")

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          ZStack {
            Image(systemName: "square.and.arrow.down")
              .font(.system(size: 15, weight: .bold))
              .foregroundColor(Theme.accent)
            Text("A")
              .font(.system(size: 8, weight: .black, design: .rounded))
              .foregroundColor(Theme.accent)
              .padding(2)
              .background(Circle().fill(Theme.bgDeep))
              .offset(x: 7, y: -7)
          }
          .frame(width: 26)

          Text("自动转存")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textPrimary)

          Spacer()

          // 三个目标图标
          HStack(spacing: 2) {
            targetButton("checkmark", "none")
            targetButton("photo.on.rectangle", "photos")
            targetButton("folder", "files")
          }
          .padding(3)
          .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .padding(15)

        divider

        Toggle(isOn: $prefs.autoSaveAfterDone) {
          VStack(alignment: .leading, spacing: 2) {
            Text("下载完成后自动转存")
              .font(.system(size: 13, weight: .medium))
              .foregroundColor(Theme.textPrimary)
            Text("可存到相册、文件 App 或两者")
              .font(.system(size: 10))
              .foregroundColor(Theme.textTertiary)
          }
        }
        .tint(Theme.accent)
        .padding(15)
      }
      .glassCard(radius: 16)

      Text("可在系统文件 App 中添加本地 NAS，以节省存储空间。")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.8))
        .padding(.leading, 4)
    }
  }

  private func targetButton(_ symbol: String, _ value: String) -> some View {
    Button {
      prefs.autoSaveTarget = value
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(prefs.autoSaveTarget == value ? Theme.bgDeep : Theme.textSecondary)
        .frame(width: 34, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(prefs.autoSaveTarget == value
                  ? Color.white.opacity(0.92)
                  : Color.clear)
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: 高级

  private var advancedSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      sectionLabel("高级")
      NavigationLink { AdvancedSettingsView() } label: {
        HStack {
          Text("高级")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textPrimary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.textTertiary)
        }
        .padding(15)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .glassCard(radius: 16)
    }
  }

  // MARK: 组件

  private func sectionLabel(_ text: String) -> some View {
    HStack(spacing: 7) {
      Rectangle()
        .fill(Theme.accentGradient)
        .frame(width: 2.5, height: 11)
        .clipShape(Capsule())
      Text(text)
        .font(.system(size: 11, weight: .bold))
        .tracking(1.6)
        .foregroundColor(Theme.textTertiary)
      Spacer()
    }
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.055))
      .frame(height: 1)
      .padding(.leading, 15)
  }

  private func miniChip(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold))
      .foregroundColor(Theme.textSecondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.white.opacity(0.07)))
  }

  private func resetDefaults() {
    prefs.maxConcurrentTasks = 0
    prefs.autoSelectEnabled = true
    prefs.autoSelectVideoHeight = 1080
    prefs.autoSelectAudio = true
    prefs.autoSelectImage = false
    prefs.transcodeVideo = false
    prefs.transcodeAudio = false
    prefs.autoSaveAfterDone = false
    prefs.autoSaveTarget = "photos"
  }
}

// MARK: - 高级设置

struct AdvancedSettingsView: View {
  @EnvironmentObject private var prefs: Prefs

  var body: some View {
    ZStack {
      AuroraBackground()
      ScrollView {
        VStack(spacing: 20) {
          VStack(spacing: 0) {
            stepperRow("单段最小字节", value: "2 MB", note: "切太细会让请求开销盖过收益")
            divider
            stepperRow("单段重试次数", value: "4", note: "失败退避 1.8^n × 400ms")
            divider
            stepperRow("探测超时", value: "20 秒", note: "GET + Range: bytes=0-0")
            divider
            stepperRow("连接数/主机", value: "32", note: "避开 URLSession 默认的 6")
          }
          .glassCard(radius: 16)

          Text("这些是编译期常量，改源码 ThunderLite/DownloadEngine.swift 里的 EngineLimits 才能调整。")
            .font(.system(size: 10))
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
      }
    }
    .navigationTitle("高级")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func stepperRow(_ title: String, value: String, note: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(Theme.textPrimary)
        Text(note)
          .font(.system(size: 10))
          .foregroundColor(Theme.textTertiary)
      }
      Spacer()
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundColor(Theme.accent)
    }
    .padding(15)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.055))
      .frame(height: 1)
      .padding(.leading, 15)
  }
}
