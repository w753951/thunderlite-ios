import Foundation
import WebKit
import UIKit

// MARK: - 用 WebView 会话下载

/// 通过 WKDownload 下载媒体。
///
/// 为什么用它而不是 URLSession：
///   WKDownload 跑在 WebView 自己的网络栈里，UA、Cookie、Referer、
///   TLS 会话全都和页面一致。抖音/微博这类 CDN 就是按这套东西放行的，
///   所以「预览能播但 URLSession 下 403」的根子就没了。
///
/// 代价是拿不到分段能力（不能多线程 Range），但对这些带签名的短时效直链
/// 来说，能下下来比下得快重要得多。
@MainActor
final class WebKitDownloader: NSObject, ObservableObject {

  enum Outcome {
    case success(URL)          // 落地到临时文件
    case failure(Error)
  }

  private var web: WKWebView?
  private var download: WKDownload?
  private var destination: URL?
  private var completion: ((Outcome) -> Void)?
  private var progressHandler: ((Int64, Int64) -> Void)?
  private var observations: [NSKeyValueObservation] = []
  private var watchdog: Timer?
  private var finished = false

  /// 下载一个 URL 到 `to`。
  ///
  /// - Parameter referer: 有些站点要求 Referer，webview 里用 JS 造一个
  ///   同源 iframe 拿不到，所以直接用请求头补。
  func download(url: URL,
                to destination: URL,
                referer: String? = nil,
                userAgent: String? = nil,
                timeout: TimeInterval = 120,
                progress: ((Int64, Int64) -> Void)? = nil,
                completion: @escaping (Outcome) -> Void) {

    cleanup()
    self.destination = destination
    self.completion = completion
    self.progressHandler = progress
    self.finished = false

    let cfg = WKWebViewConfiguration()
    // 关键：用默认的持久化 store，Cookie 和登录态和探索页一致
    cfg.websiteDataStore = .default()
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []

    let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
    w.navigationDelegate = self
    if let ua = userAgent {
      w.customUserAgent = ua
    }
    // 必须真正挂到窗口层级里，否则 WKDownload 可能不启动。
    // 用很小的尺寸 + 全透明，用户看不见。
    w.alpha = 0
    w.isUserInteractionEnabled = false
    if let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
       let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
      win.addSubview(w)
    }
    web = w

    var req = URLRequest(url: url)
    req.timeoutInterval = 60
    if let referer {
      req.setValue(referer, forHTTPHeaderField: "Referer")
    }
    w.load(req)

    // 看门狗：WKDownload 偶尔会卡住不回调，兜一个硬超时
    watchdog = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.finish(.failure(NSError(
          domain: "ThunderLite", code: -1001,
          userInfo: [NSLocalizedDescriptionKey: "WebView 下载超时。"])))
      }
    }
  }

  /// 取消正在进行的下载。
  func cancel() {
    if finished { return }
    download?.cancel { _ in }
    finish(.failure(NSError(
      domain: "ThunderLite", code: -999,
      userInfo: [NSLocalizedDescriptionKey: "已取消。"])))
  }

  // MARK: 收尾

  private func finish(_ outcome: Outcome) {
    guard !finished else { return }
    finished = true
    watchdog?.invalidate()
    watchdog = nil
    observations.removeAll()

    if let cb = completion {
      completion = nil
      cb(outcome)
    }
    cleanup()
  }

  private func cleanup() {
    if let w = web {
      w.stopLoading()
      w.removeFromSuperview()
      w.navigationDelegate = nil
      if let d = download {
        _ = d
      }
    }
    web = nil
    download = nil
  }
}

// MARK: - 导航与下载回调

extension WebKitDownloader: WKNavigationDelegate {

  /// 媒体直链不是网页，让 WebKit 转成下载。
  nonisolated func webView(_ webView: WKWebView,
                           decidePolicyFor navigationAction: WKNavigationAction,
                           decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    // 2 = .download
    decisionHandler(.download)
  }

  /// 只允许第一个导航成为下载，后续（重定向）按普通请求走。
  nonisolated func webView(_ webView: WKWebView,
                           decidePolicyFor navigationResponse: WKNavigationResponse,
                           decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    // 是 HTML 说明被重定向到了登录页/错误页
    if navigationResponse.response.mimeType == "text/html" {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.download)
  }

  nonisolated func webView(_ webView: WKWebView,
                           navigationAction: WKNavigationAction,
                           didBecome download: WKDownload) {
    Task { @MainActor in self.attach(download) }
  }

  nonisolated func webView(_ webView: WKWebView,
                           navigationResponse: WKNavigationResponse,
                           didBecome download: WKDownload) {
    Task { @MainActor in self.attach(download) }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    Task { @MainActor in self.finish(.failure(error)) }
  }

  nonisolated func webView(_ webView: WKWebView,
                           didFailProvisionalNavigation navigation: WKNavigation!,
                           withError error: Error) {
    Task { @MainActor in self.finish(.failure(error)) }
  }

  private func attach(_ d: WKDownload) {
    download = d
    d.delegate = self

    // 进度
    observations.append(
      d.progress.observe(\.totalUnitCount, options: [.new]) { [weak self] p, _ in
        Task { @MainActor in
          self?.progressHandler?(p.completedUnitCount, p.totalUnitCount)
        }
      }
    )
    observations.append(
      d.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] p, _ in
        Task { @MainActor in
          self?.progressHandler?(p.completedUnitCount, p.totalUnitCount)
        }
      }
    )
  }
}

extension WebKitDownloader: WKDownloadDelegate {

  nonisolated func download(_ download: WKDownload,
                            decideDestinationUsing response: URLResponse,
                            suggestedFilename: String,
                            completionHandler: @escaping (URL?) -> Void) {
    Task { @MainActor in
      // 关键：先看响应本身像不像媒体文件。
      //
      // CDN 拒绝时通常回一个很小的 JSON/HTML 错误体（100~500 字节），
      // WKDownload 会老老实实把它存成 .mp4 —— 结果就是「下载成功但文件 150 字节」。
      // 这里在落盘前就拦下来，把状态码和 MIME 报给上层。
      if let http = response as? HTTPURLResponse {
        let code = http.statusCode
        let mime = (http.mimeType ?? "").lowercased()
        let expected = max(response.expectedContentLength, 0)

        let badStatus = !(200...299).contains(code)
        let badMime = mime.hasPrefix("text/")
          || mime.contains("json")
          || mime.contains("html")
          || mime.contains("xml")
        // 小于 4KB 的「视频」一定是错误体：最短的有效 mp4 也远大于这个
        let tooSmall = expected > 0 && expected < 4096

        if badStatus || badMime || tooSmall {
          completionHandler(nil)
          let reason: String
          if badStatus {
            reason = "HTTP \(code)"
          } else if badMime {
            reason = "服务器返回的是 \(mime) 而不是媒体文件"
          } else {
            reason = "文件只有 \(expected) 字节，不是真正的视频"
          }
          self.failWith(NSError(
            domain: "ThunderLite", code: code == 0 ? -1 : code,
            userInfo: [NSLocalizedDescriptionKey:
              "CDN 拒绝了这次请求（\(reason)），直链可能已过期。"]))
          return
        }
      }

      guard let dest = self.destination else {
        completionHandler(nil)
        return
      }
      let fm = FileManager.default
      try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                              withIntermediateDirectories: true)
      try? fm.removeItem(at: dest)
      completionHandler(dest)
    }
  }

  /// 主动以失败收尾（decideDestination 里判定不合适时用）。
  private func failWith(_ error: Error) {
    if let d = download {
      d.cancel { _ in }
    }
    finish(.failure(error))
  }

  nonisolated func downloadDidFinish(_ download: WKDownload) {
    Task { @MainActor in
      guard let dest = self.destination else {
        self.finish(.failure(NSError(domain: "ThunderLite", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "目标路径丢失。"])))
        return
      }

      // 落盘后再查一次大小和文件头。
      // 有些 CDN 不在响应头里给 Content-Length，decideDestination 拦不住，
      // 只能等下完看实际内容。
      let fm = FileManager.default
      let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0

      if size < 4096 {
        try? fm.removeItem(at: dest)
        self.finish(.failure(NSError(
          domain: "ThunderLite", code: -2,
          userInfo: [NSLocalizedDescriptionKey:
            "下载到的内容只有 \(size) 字节，是 CDN 的错误响应而不是视频。直链已过期。"])))
        return
      }

      // 认一下文件头：mp4 是 ftyp，webm 是 EBML(1A45DFA3)，flv 是 FLV
      if let head = Self.readHead(dest, count: 16) {
        let mp4 = head.count >= 12
          && head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70
        let webm = head.count >= 4
          && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3
        let flv = head.count >= 3
          && head[0] == 0x46 && head[1] == 0x4C && head[2] == 0x56
        let isMP3 = head.count >= 3
          && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33

        if !(mp4 || webm || flv || isMP3) {
          // 不是已知媒体格式：多半还是错误页
          try? fm.removeItem(at: dest)
          self.finish(.failure(NSError(
            domain: "ThunderLite", code: -3,
            userInfo: [NSLocalizedDescriptionKey:
              "下载到的不是有效的媒体文件（文件头不匹配），直链已过期。"])))
          return
        }
      }

      self.finish(.success(dest))
    }
  }

  /// 读文件前 N 个字节。
  private static func readHead(_ url: URL, count: Int) -> [UInt8]? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    guard let data = try? fh.read(upToCount: count) else { return nil }
    return [UInt8](data)
  }

  nonisolated func download(_ download: WKDownload,
                            didFailWithError error: Error,
                            resumeData: Data?) {
    Task { @MainActor in self.finish(.failure(error)) }
  }
}
