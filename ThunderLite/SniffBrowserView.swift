import SwiftUI
import WebKit

// MARK: - WKWebView 封装

/// 带嗅探注入的浏览器。
///
/// 加载逻辑放在 Coordinator 里用 `lastRequested` 记录，避免「URL 字符串不等就重载」。
/// 之前用 `web.url.absoluteString != url.absoluteString` 判断，会踩这个坑：
///   URL(string: "https://www.douyin.com")!.absoluteString == "https://www.douyin.com"
///   加载完成后 web.url.absoluteString == "https://www.douyin.com/"   ← 多个尾斜杠
/// 两者不等 → 每次 SwiftUI 刷新都重新 load → 页面永远加载不完，表现为全黑。
struct SnifferWebView: UIViewRepresentable {
  @ObservedObject var store: SnifferStore
  let url: URL
  @Binding var progress: Double
  @Binding var pageTitle: String
  @Binding var canGoBack: Bool
  @Binding var canGoForward: Bool
  @Binding var command: BrowserCommand?

  /// 加载失败时把原因抛给上层显示。
  @Binding var loadError: String?

  var adBlockEnabled: Bool = false
  var userAgent: String? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> WKWebView {
    let cfg = WKWebViewConfiguration()

    let ucc = WKUserContentController()
    ucc.addUserScript(WKUserScript(source: SnifferScript.source,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: false))
    ucc.add(context.coordinator, name: "tlSniffer")

    if adBlockEnabled {
      ucc.addUserScript(WKUserScript(source: AdBlocker.pageScript,
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: false))
      ucc.add(context.coordinator, name: "tlAdBlock")
      if let list = AdBlocker.cachedList {
        ucc.add(list)
      }
    }
    cfg.userContentController = ucc

    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    cfg.applicationNameForUserAgent = "Safari/604.1"

    let web = WKWebView(frame: .zero, configuration: cfg)
    web.navigationDelegate = context.coordinator
    web.uiDelegate = context.coordinator
    web.allowsBackForwardNavigationGestures = true
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.isOpaque = true
    web.backgroundColor = UIColor(white: 0.04, alpha: 1)
    web.scrollView.backgroundColor = UIColor(white: 0.04, alpha: 1)

    if let ua = userAgent {
      web.customUserAgent = ua
    }

    context.coordinator.observe(web)
    // 让下载兜底逻辑能找到这个已经登录过站点的 webview
    SharedWebView.shared.register(web)
    context.coordinator.load(url, in: web)
    return web
  }

  func updateUIView(_ web: WKWebView, context: Context) {
    // SwiftUI 每次重绘都会造新的 struct，Coordinator 里那份 parent 要跟着换，
    // 否则 @Binding 写回的是已经失效的旧副本。
    context.coordinator.update(parent: self)

    // 只有「请求的地址真的变了」才加载，Coordinator 里自己比对
    context.coordinator.load(url, in: web)

    if let cmd = command {
      context.coordinator.perform(cmd, in: web)
      DispatchQueue.main.async { command = nil }
    }
  }

  static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
    web.configuration.userContentController.removeScriptMessageHandler(forName: "tlSniffer")
    web.configuration.userContentController.removeScriptMessageHandler(forName: "tlAdBlock")
    web.stopLoading()
    web.navigationDelegate = nil
    web.uiDelegate = nil
  }

  // MARK: Coordinator

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
                           WKScriptMessageHandler {
    private var parent: SnifferWebView
    private var observations: [NSKeyValueObservation] = []

    /// 已经请求加载过的地址。用来去重，防止无限重载。
    private var lastRequested: String?

    init(_ parent: SnifferWebView) { self.parent = parent }

    /// 上层 parent 是 struct，SwiftUI 每次都会传新的，要跟着换。
    func update(parent: SnifferWebView) {
      self.parent = parent
    }

    func observe(_ web: WKWebView) {
      observations = [
        web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
          DispatchQueue.main.async { self?.parent.progress = w.estimatedProgress }
        },
        web.observe(\.title, options: [.new]) { [weak self] w, _ in
          DispatchQueue.main.async { self?.parent.pageTitle = w.title ?? "" }
        },
        web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
          DispatchQueue.main.async { self?.parent.canGoBack = w.canGoBack }
        },
        web.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in
          DispatchQueue.main.async { self?.parent.canGoForward = w.canGoForward }
        },
      ]
    }

    /// 统一的加载入口：比对「规范化后」的地址，相同就跳过。
    func load(_ url: URL, in web: WKWebView) {
      let key = normalized(url)
      guard key != lastRequested else { return }
      lastRequested = key

      DispatchQueue.main.async { [weak self] in
        self?.parent.loadError = nil
        self?.parent.progress = 0.05
      }

      var req = URLRequest(url: url)
      req.timeoutInterval = 30
      // 部分站点对无 Referer 的请求返回空页
      if let host = url.host {
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
      }
      web.load(req)
    }

    /// 把 URL 规范化成可比较的字符串：补尾斜杠、去掉末尾多余斜杠差异。
    private func normalized(_ url: URL) -> String {
      var s = url.absoluteString
      // about:blank 直接原样比
      if s.hasPrefix("about:") { return s }
      // 去掉 fragment（不影响服务端返回的内容）
      if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
      // 统一尾斜杠
      if !s.hasSuffix("/") { s += "/" }
      return s
    }

    func perform(_ cmd: BrowserCommand, in web: WKWebView) {
      switch cmd {
      case .back:
        if web.canGoBack {
          lastRequested = nil          // 返回是导航，允许后续再次 load 同一地址
          web.goBack()
        }
      case .forward:
        if web.canGoForward {
          lastRequested = nil
          web.goForward()
        }
      case .reload:
        lastRequested = nil
        web.reload()
      case .stop:
        web.stopLoading()
      }
    }

    // MARK: JS → Native

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
      if message.name == "tlSniffer",
         let body = message.body as? [String: Any] {
        Task { @MainActor in parent.store.ingest(body) }
        return
      }
      if message.name == "tlAdBlock" {
        let body = message.body
        Task { @MainActor in AdBlockStore.shared.record(body) }
      }
    }

    // MARK: 导航回调

    func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      DispatchQueue.main.async { [weak self] in
        self?.parent.loadError = nil
      }
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.parent.progress = 1
        self.parent.pageTitle = web.title ?? ""
        self.parent.canGoBack = web.canGoBack
        self.parent.canGoForward = web.canGoForward
        if self.lastRequested == nil {
          self.lastRequested = web.url.map { self.normalized($0) }
        }
      }
    }

    func webView(_ web: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
      reportFailure(error)
    }

    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
      reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
      let ns = error as NSError
      // 用户主动取消（例如点了停止）不算错误
      if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }

      var text = ns.localizedDescription
      if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet:
          text = "没有网络连接。"
        case NSURLErrorTimedOut:
          text = "连接超时，站点可能被网络屏蔽。"
        case NSURLErrorCannotFindHost:
          text = "找不到这个域名。"
        case NSURLErrorCannotConnectToHost:
          text = "连不上服务器。"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted:
          text = "HTTPS 证书错误。"
        case NSURLErrorNetworkConnectionLost:
          text = "网络中断。"
        default:
          break
        }
      }

      DispatchQueue.main.async { [weak self] in
        self?.parent.loadError = text
        self?.parent.progress = 0
      }
    }

    /// 让 target="_blank" 在当前 webview 里打开。
    func webView(_ web: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
      if navigationAction.targetFrame == nil {
        lastRequested = nil
        web.load(navigationAction.request)
      }
      return nil
    }
  }
}

enum BrowserCommand {
  case back, forward, reload, stop
}
