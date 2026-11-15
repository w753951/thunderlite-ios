import SwiftUI
import WebKit

// MARK: - WKWebView 封装

/// 带嗅探注入的浏览器。
struct SnifferWebView: UIViewRepresentable {
  @ObservedObject var store: SnifferStore
  let url: URL
  @Binding var progress: Double
  @Binding var pageTitle: String
  @Binding var canGoBack: Bool
  @Binding var canGoForward: Bool
  /// 由外部触发 reload / goBack / goForward。
  @Binding var command: BrowserCommand?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> WKWebView {
    let cfg = WKWebViewConfiguration()

    // 可被 JS 注入的 UserContentController
    let ucc = WKUserContentController()
    let script = WKUserScript(source: SnifferScript.source,
                              injectionTime: .atDocumentStart,
                              forMainFrameOnly: false)
    ucc.addUserScript(script)
    ucc.add(context.coordinator, name: "tlSniffer")
    cfg.userContentController = ucc

    // 允许内联播放，不然 iOS 会强行全屏
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []

    // 服务端拿不到的部分靠这里兜一层：给 UA 加个移动端标识
    cfg.applicationNameForUserAgent = "Safari/604.1"

    let web = WKWebView(frame: .zero, configuration: cfg)
    web.navigationDelegate = context.coordinator
    web.uiDelegate = context.coordinator
    web.allowsBackForwardNavigationGestures = true
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.isOpaque = false
    web.backgroundColor = .clear
    web.scrollView.backgroundColor = .clear

    context.coordinator.observe(web)
    web.load(URLRequest(url: url))
    return web
  }

  func updateUIView(_ web: WKWebView, context: Context) {
    // 只有在外部指定了新地址且和当前不同时才重新加载
    if let cur = web.url?.absoluteString,
       cur != url.absoluteString,
       !url.absoluteString.isEmpty {
      web.load(URLRequest(url: url))
    }

    if let cmd = command {
      DispatchQueue.main.async {
        switch cmd {
        case .back: if web.canGoBack { web.goBack() }
        case .forward: if web.canGoForward { web.goForward() }
        case .reload: web.reload()
        case .stop: web.stopLoading()
        }
        command = nil
      }
    }
  }

  static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
    web.configuration.userContentController.removeScriptMessageHandler(forName: "tlSniffer")
    web.stopLoading()
    web.navigationDelegate = nil
    web.uiDelegate = nil
  }

  // MARK: Coordinator

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
                           WKScriptMessageHandler {
    private let parent: SnifferWebView
    private var observations: [NSKeyValueObservation] = []

    init(_ parent: SnifferWebView) { self.parent = parent }

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

    // JS → Native
    func userContentController(_ ucc: WKUserContentController,
                              didReceive message: WKScriptMessage) {
      guard message.name == "tlSniffer",
            let body = message.body as? [String: Any] else { return }
      Task { @MainActor in parent.store.ingest(body) }
    }

    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
      Task { @MainActor in
        parent.progress = 1
        parent.pageTitle = web.title ?? ""
        parent.canGoBack = web.canGoBack
        parent.canGoForward = web.canGoForward
      }
    }

    /// 让 target="_blank" 在当前 webview 里打开。
    func webView(_ web: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
      if navigationAction.targetFrame == nil {
        web.load(navigationAction.request)
      }
      return nil
    }
  }
}

enum BrowserCommand {
  case back, forward, reload, stop
}
