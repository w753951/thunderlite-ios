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
    download?.cancel { }
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
      guard let dest = self.destination else {
        completionHandler(nil)
        return
      }
      // 用调用方指定的文件名，扩展名从 suggestedFilename 里补
      let fm = FileManager.default
      try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                              withIntermediateDirectories: true)
      // 已存在就删掉，WKDownload 不会覆盖
      try? fm.removeItem(at: dest)
      completionHandler(dest)
    }
  }

  nonisolated func downloadDidFinish(_ download: WKDownload) {
    Task { @MainActor in
      guard let dest = self.destination else {
        self.finish(.failure(NSError(domain: "ThunderLite", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "目标路径丢失。"])))
        return
      }
      self.finish(.success(dest))
    }
  }

  nonisolated func download(_ download: WKDownload,
                            didFailWithError error: Error,
                            resumeData: Data?) {
    Task { @MainActor in self.finish(.failure(error)) }
  }
}
