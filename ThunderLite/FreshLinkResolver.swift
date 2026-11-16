import Foundation
import WebKit

// MARK: - 直链刷新

/// 用隐藏的 WKWebView 重新访问来源页，从页面里抓一条「新鲜的」媒体直链。
///
/// 为什么需要：抖音/微博/B站的 CDN 直链带过期签名（URL 里常见 `expire=`、
/// `validity=`、`e=` 这类参数），而且和当前会话绑定。剪贴板里拿到的、
/// 或者几分钟前嗅到的链接，用它去下必然 403 —— 但用同一个地址在浏览器里
/// 还能播，因为播放器走了新的签名。
///
/// 这里的做法：加载原页面，等它自己把媒体请求发出去，从网络层再嗅一次。
@MainActor
final class FreshLinkResolver: NSObject, ObservableObject {

  enum State {
    case idle, resolving, success(URL), failed(String)
  }

  @Published private(set) var state: State = .idle

  private var web: WKWebView?
  private var targetKinds: Set<String> = ["video"]
  private var found: [URL] = []
  private var finishTimer: Timer?

  /// 在 `pageURL` 里找一条和 `mediaHost` 同域（或同类）的媒体直链。
  ///
  /// - Parameter pageURL: 媒体所在页面的地址（通常是 Referer 那个域名下的页面）
  /// - Parameter mediaHost: 原直链的域名，用来挑出同一个 CDN 上的新链
  func refresh(pageURL: URL,
               mediaHost: String?,
               timeout: TimeInterval = 20,
               completion: @escaping (URL?) -> Void) {

    cleanup()
    state = .resolving
    found = []

    let cfg = WKWebViewConfiguration()
    // 用持久化 store：必须带上现有登录态，否则站点给的是未登录的低清或直接拒绝
    cfg.websiteDataStore = .default()

    let ucc = WKUserContentController()
    ucc.addUserScript(WKUserScript(source: Self.hookScript,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: false))
    ucc.add(self, name: "freshLink")
    cfg.userContentController = ucc
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []

    let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700),
                      configuration: cfg)
    w.navigationDelegate = self
    w.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    // 放在窗口外，用户看不到，但页面能正常执行
    w.isHidden = true
    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let win = scene.windows.first {
      win.addSubview(w)
    }
    web = w

    var req = URLRequest(url: pageURL)
    req.setValue("https://\(pageURL.host ?? "")/", forHTTPHeaderField: "Referer")
    w.load(req)

    // 到点就收，不管找没找到
    finishTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let best = self.pickBest(mediaHost: mediaHost)
        self.state = best.map { .success($0) } ?? .failed("没抓到新的直链")
        completion(best)
        self.cleanup()
      }
    }
  }

  /// 挑一条最合适的：优先同域，其次码率/清晰度关键字最高的。
  private func pickBest(mediaHost: String?) -> URL? {
    guard !found.isEmpty else { return nil }

    let sameHost = found.filter { u in
      guard let h = u.host, let target = mediaHost else { return false }
      return h == target || h.hasSuffix("." + target) || target.hasSuffix("." + h)
    }

    let pool = sameHost.isEmpty ? found : sameHost

    // 按 URL 里能看出的清晰度排序
    func score(_ u: URL) -> Int {
      let s = u.absoluteString.lowercased()
      if s.contains("30080") || s.contains("2160") { return 100 }
      if s.contains("30077") || s.contains("1440") { return 90 }
      if s.contains("30064") || s.contains("1080") { return 80 }
      if s.contains("30032") || s.contains("720") { return 70 }
      if s.contains("480") { return 60 }
      return 50
    }

    return pool.max { score($0) < score($1) }
  }

  private func cleanup() {
    finishTimer?.invalidate()
    finishTimer = nil
    web?.stopLoading()
    web?.removeFromSuperview()
    web?.configuration.userContentController
      .removeScriptMessageHandler(forName: "freshLink")
    web = nil
  }

  // MARK: 注入脚本

  /// 只做一件事：把所有媒体请求报上来。
  private static let hookScript = #"""
  (function () {
    if (window.__tlFresh) { return; }
    window.__tlFresh = true;
    var post = function (u) {
      if (!u) { return; }
      var s;
      try { s = String(u); } catch (e) { return; }
      var l = s.slice(0, 5).toLowerCase();
      if (l === 'data:' || l === 'blob:' || l === 'about') { return; }
      try { window.webkit.messageHandlers.freshLink.postMessage({ url: s }); } catch (e) {}
    };
    var ok = function (u) {
      if (!u) { return false; }
      return /\.(mp4|m4s|m3u8|flv|ts|webm|mp3|m4a)(\?|$)/i.test(String(u))
          || /videoplayback|playwm|play\/|\/video\/tos\//i.test(String(u));
    };
    try {
      var xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        try { if (ok(u)) { post(u); } } catch (e) {}
        return xo.apply(this, arguments);
      };
    } catch (e) {}
    try {
      var of = window.fetch;
      if (of) {
        window.fetch = function (input) {
          try {
            var u = (typeof input === 'string') ? input : (input && input.url);
            if (ok(u)) { post(u); }
          } catch (e) {}
          return of.apply(this, arguments);
        };
      }
    } catch (e) {}
    var scan = function () {
      try {
        var v = document.querySelectorAll('video,audio,source');
        for (var i = 0; i < v.length; i++) {
          var u = v[i].currentSrc || v[i].src;
          if (u && ok(u)) { post(u); }
        }
      } catch (e) {}
    };
    scan();
    setInterval(scan, 1200);
  })();
  """#
}

extension FreshLinkResolver: WKNavigationDelegate, WKScriptMessageHandler {
  nonisolated func userContentController(_ ucc: WKUserContentController,
                                         didReceive message: WKScriptMessage) {
    guard message.name == "freshLink",
          let body = message.body as? [String: Any],
          let s = body["url"] as? String,
          let u = URL(string: s) else { return }
    Task { @MainActor in
      if !self.found.contains(u) { self.found.append(u) }
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // 页面加载完后主动点一下播放，逼它去拉流
    Task { @MainActor in
      webView.evaluateJavaScript("""
        (function(){
          var v = document.querySelector('video');
          if (v) { try { v.muted = true; v.play(); } catch(e){} }
          var btns = document.querySelectorAll('[class*=play],[aria-label*=播放],[aria-label*=Play]');
          if (btns.length) { try { btns[0].click(); } catch(e){} }
        })();
      """) { _, _ in }
    }
  }
}

// MARK: - 异步桥

/// 把回调式的 FreshLinkResolver 包成 async，供引擎直接 await。
///
/// DownloadEngine 是 @MainActor，里的 run() 想 await 主线程上的 WebView 操作时，
/// 用 continuition 把回调转成 async 最省事。
@MainActor
final class FreshLinkBridge {
  static let shared = FreshLinkBridge()

  private var resolver: FreshLinkResolver?

  func refresh(pageURL: URL, mediaHost: String?) async -> URL? {
    await withCheckedContinuation { cont in
      let r = FreshLinkResolver()
      resolver = r
      r.refresh(pageURL: pageURL, mediaHost: mediaHost) { url in
        cont.resume(returning: url)
      }
    }
  }
}
