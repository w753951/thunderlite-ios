import SwiftUI
import AVKit
import UIKit

// MARK: - 预览页

/// 点资源后弹出的预览：视频能播、图片能看、音频能听，底部一键下载。
struct MediaPreviewSheet: View {
  let media: SniffedMedia
  @EnvironmentObject private var engine: DownloadEngine
  @EnvironmentObject private var prefs: Prefs
  @Environment(\.dismiss) private var dismiss

  @State private var player: AVPlayer?
  @State private var loadFailed = false
  @State private var added = false

  var body: some View {
    ZStack {
      AuroraBackground()

      VStack(spacing: 0) {
        topBar
        previewArea
        infoArea
        Spacer(minLength: 0)
        actionBar
      }
    }
    .onAppear { prepare() }
    .onDisappear { player?.pause() }
  }

  // MARK: 顶栏

  private var topBar: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: media.kind.symbol)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(Theme.accent)
        Text(media.kind.title + "预览")
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundColor(Theme.textPrimary)
      }
      Spacer()
      Button { dismiss() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundColor(Theme.textSecondary)
          .frame(width: 32, height: 32)
          .background(Circle().fill(Color.white.opacity(0.07)))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 14)
  }

  // MARK: 预览区

  @ViewBuilder
  private var previewArea: some View {
    Group {
      switch media.kind {
      case .image:
        imagePreview
      case .video:
        videoPreview
      case .audio:
        audioPreview
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 300)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.black.opacity(0.42))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .padding(.horizontal, 20)
  }

  private var imagePreview: some View {
    ZStack {
      AsyncImage(url: media.url) { phase in
        switch phase {
        case .success(let img):
          img.resizable().scaledToFit()
        case .failure:
          fallbackView("图片加载失败", "wifi.exclamationmark")
        case .empty:
          ProgressView().tint(Theme.accent)
        @unknown default:
          fallbackView("无法显示", "questionmark")
        }
      }
    }
    .padding(10)
  }

  private var videoPreview: some View {
    ZStack {
      if loadFailed {
        fallbackView(media.isManifest ? "这是流媒体清单，需要在播放器里打开" : "无法预览",
                     media.isManifest ? "list.bullet.rectangle" : "film")
      } else if let player {
        VideoPlayer(player: player)
          .onAppear { player.play() }
      } else {
        ProgressView().tint(Theme.accent)
      }
    }
  }

  private var audioPreview: some View {
    ZStack {
      if loadFailed {
        fallbackView("无法预览音频", "waveform.slash")
      } else if let player {
        VStack(spacing: 16) {
          ZStack {
            Circle()
              .fill(Theme.accent.opacity(0.12))
              .frame(width: 96, height: 96)
            Circle()
              .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1)
              .frame(width: 120, height: 120)
            Image(systemName: "waveform")
              .font(.system(size: 32, weight: .light))
              .foregroundColor(Theme.accent)
          }
          VideoPlayer(player: player)
            .frame(height: 50)
            .disabled(true)
        }
        .onAppear { player.play() }
      } else {
        ProgressView().tint(Theme.accent)
      }
    }
  }

  private func fallbackView(_ text: String, _ symbol: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 32, weight: .light))
        .foregroundColor(Theme.textTertiary)
      Text(text)
        .font(.system(size: 12))
        .foregroundColor(Theme.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
  }

  // MARK: 信息区

  private var infoArea: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(media.suggestedName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(Theme.textPrimary)
        .lineLimit(2)
        .truncationMode(.middle)

      HStack(spacing: 6) {
        if !media.quality.isEmpty {
          chip(media.quality,
               media.isHighQuality ? Theme.accentWarm : Theme.accentAlt)
        }
        if let size = media.pixelSize {
          chip(size, Theme.accentAlt)
        }
        chip(media.url.host ?? "未知来源", Theme.textSecondary)
        if media.isManifest {
          chip("HLS 流", Theme.accentWarm)
        }
      }

      Text(media.url.absoluteString)
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(Theme.textTertiary)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
    .padding(.top, 16)
  }

  private func chip(_ text: String, _ color: Color) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(color.opacity(0.14)))
      .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 1))
      .foregroundColor(color)
  }

  // MARK: 底部操作

  private var actionBar: some View {
    VStack(spacing: 10) {
      Button { addToDownloads() } label: {
        HStack(spacing: 8) {
          Image(systemName: added ? "checkmark" : "arrow.down.circle.fill")
            .font(.system(size: 15, weight: .bold))
          Text(added ? "已加入下载" : "下载到本机")
            .font(.system(size: 15, weight: .semibold))
        }
        .foregroundColor(Theme.bgDeep)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(
          Group {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
              .fill(added ? Color(hex: 0x35E08A) : Color.clear)
              .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                  .fill(added ? LinearGradient(colors: [.clear, .clear],
                                               startPoint: .top, endPoint: .bottom)
                              : Theme.accentGradient)
                  .opacity(added ? 0 : 1)
              )
          }
        )
        .shadow(color: Theme.accent.opacity(added ? 0 : 0.4), radius: 14, x: 0, y: 5)
      }
      .buttonStyle(.plain)
      .disabled(added)

      HStack(spacing: 10) {
        smallButton("复制链接", "link") {
          UIPasteboard.general.string = media.url.absoluteString
        }
        smallButton("用 Safari 打开", "safari") {
          UIApplication.shared.open(media.url)
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 24)
    .padding(.top, 14)
  }

  private func smallButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .semibold))
        Text(title)
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundColor(Theme.textSecondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 11)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.white.opacity(0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: 逻辑

  private func prepare() {
    guard media.kind == .video || media.kind == .audio else { return }
    guard !media.isManifest else { loadFailed = true; return }

    let p = AVPlayer(url: media.url)
    p.actionAtItemEnd = .pause
    player = p

    // AVPlayer 不会抛错，只能观察 item 状态
    if let item = p.currentItem {
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: item, queue: .main) { _ in
          loadFailed = true
        }
    }
  }

  private func addToDownloads() {
    // 这些站点的 CDN 都校验 Referer，不带会 403
    var headers: [String: String] = [:]
    if let host = media.url.host {
      if host.contains("bilibili") || host.contains("hdslb") {
        headers["Referer"] = "https://www.bilibili.com/"
      } else if host.contains("douyin") || host.contains("byteimg")
                  || host.contains("douyinvod") {
        headers["Referer"] = "https://www.douyin.com/"
      }
    }
    do {
      try engine.add(url: media.url.absoluteString,
                     saveTo: prefs.saveDirectory(),
                     threads: prefs.threads,
                     extraHeaders: headers)
      added = true
    } catch {
      UIPasteboard.general.string = media.url.absoluteString
    }
  }
}
