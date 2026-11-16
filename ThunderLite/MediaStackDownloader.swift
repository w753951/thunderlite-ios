import Foundation
import AVFoundation
import UIKit

// MARK: - 用系统媒体栈下载

/// 用 AVFoundation 下载媒体。
///
/// 为什么这条路能过 CDN：
///   用户确认过「预览能播放」—— 那是 AVPlayer 在播，走的是系统媒体栈，
///   它会带上 CDN 期望的那套东西（Sec-Fetch-* 之类的元信息、TLS 会话、
///   特定的 Range 策略），这些在 URLSession 里根本伪造不出来。
///
///   所以这里用 AVURLAsset + AVAssetExportSession(passthrough)：
///   让系统媒体栈去拉流，然后原样写出文件，不转码、不重编码。
///   同一个 URL 播放器能播，这条路就能下。
@MainActor
final class MediaStackDownloader: NSObject, ObservableObject {

  enum Failure: LocalizedError {
    case assetUnreadable(String)
    case exportFailed(String)
    case cancelled
    case noVideoTrack

    var errorDescription: String? {
      switch self {
      case .assetUnreadable(let s):
        return "媒体栈读不了这个地址：\(s)"
      case .exportFailed(let s):
        return "导出失败：\(s)"
      case .cancelled:
        return "已取消。"
      case .noVideoTrack:
        return "地址里没有可用的视频轨道。"
      }
    }
  }

  @Published private(set) var running = false
  @Published private(set) var fraction: Double = 0

  private var session: AVAssetExportSession?
  private var pollTimer: Timer?

  /// 开始下载。
  ///
  /// - Parameter headers: 会塞进 AVURLAsset 的 HTTP 头（Referer / Cookie / UA）
  func download(url: URL,
                to destination: URL,
                headers: [String: String] = [:],
                progress: ((Double) -> Void)? = nil,
                completion: @escaping (Result<URL, Error>) -> Void) {

    cleanup()

    running = true
    fraction = 0

    // 关键：AVURLAssetHTTPHeaderFieldsKey 让媒体栈带上我们的头。
    // 这个 key 是私有但社区长期在用，Apple 也没封。
    var options: [String: Any] = [:]
    if !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }

    let asset = AVURLAsset(url: url, options: options)

    // 先确认这个 asset 真的能读出轨道（相当于一次轻量探测）
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        var err: NSError?
        let status = asset.statusOfValue(forKey: "tracks", error: &err)
        if status == .failed || asset.tracks(withMediaType: .video).isEmpty {
          self.running = false
          let msg = err?.localizedDescription
            ?? "没有视频轨道（可能是分片或需要登录）"
          completion(.failure(Failure.assetUnreadable(msg)))
          return
        }
        self.startExport(asset: asset, to: destination,
                         progress: progress, completion: completion)
      }
    }
  }

  private func startExport(asset: AVAsset,
                           to destination: URL,
                           progress: ((Double) -> Void)?,
                           completion: @escaping (Result<URL, Error>) -> Void) {

    let fm = FileManager.default
    try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    try? fm.removeItem(at: destination)

    // passthrough 不转码：原样搬字节，最快也最保真
    guard let export = AVAssetExportSession(asset: asset,
                                            presetName: AVAssetExportPresetPassthrough) else {
      running = false
      completion(.failure(Failure.exportFailed("无法创建导出会话")))
      return
    }
    session = export
    export.outputURL = destination
    // 按目标扩展名选容器
    let ext = destination.pathExtension.lowercased()
    if ext == "mov" {
      export.outputFileType = .mov
    } else {
      // mp4 / m4v 都用 mp4
      if export.supportedFileTypes.contains(.mp4) {
        export.outputFileType = .mp4
      } else {
        export.outputFileType = export.supportedFileTypes.first ?? .mov
      }
    }
    export.shouldOptimizeForNetworkUse = true

    // 轮询进度（AVAssetExportSession 只有 progress 属性，没有回调）
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let s = self.session else { return }
        let p = Double(s.progress)
        self.fraction = p
        progress?(p)
      }
    }

    export.exportAsynchronously { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.pollTimer?.invalidate()
        self.pollTimer = nil
        self.running = false

        switch export.status {
        case .completed:
          completion(.success(destination))
        case .cancelled:
          completion(.failure(Failure.cancelled))
        case .failed:
          completion(.failure(Failure.exportFailed(
            export.error?.localizedDescription ?? "未知原因")))
        default:
          completion(.failure(Failure.exportFailed("导出未完成")))
        }
        self.session = nil
      }
    }
  }

  func cancel() {
    session?.cancelExport()
    cleanup()
  }

  private func cleanup() {
    pollTimer?.invalidate()
    pollTimer = nil
    running = false
  }
}
