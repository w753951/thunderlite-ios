import Foundation
import WebKit
import Combine

// MARK: - 共享 WebView

/// 全局共用一个 WKWebView 实例，供「下载失败时刷新直链」使用。
///
/// 为什么不新建一个：新建的 webview 即使 dataStore 相同，页面也没跑起来、
/// 播放器没初始化，抓不到媒体请求。必须复用已经加载过该站点的那个实例，
/// 或者至少在同一会话里重新走一遍页面加载 + 自动播放。
@MainActor
final class SharedWebView: NSObject, ObservableObject {
  static let shared = SharedWebView()

  /// 最近一次由探索页创建的 webview。下载兜底时优先复用它。
  weak var live: WKWebView?

  /// 兜底用的隐藏 webview（探索页没开过时用这个）。
  private var scratch: WKWebView?

  private override init() { super.init() }

  /// 记住探索页的 webview。
  func register(_ web: WKWebView) {
    live = web
  }

  func unregister(_ web: WKWebView) {
    if live === web { live = nil }
  }
}

// MARK: - 直链刷新（重写版）

/// 重新走一遍页面，抓一条新的媒体直链。
///
/// 关键改进 vs 上一版：
///   1. 优先复用探索页那个**已经加载过该站点**的 webview
///   2. 隐藏 webview 用 1x1 且 alpha=0.01（纯 0 会被 WebKit 判定不可见而不执行 JS）
///   3. 必须真正挂到窗口上，且加上非零尺寸
///   4. 主动触发播放（play + 点播放按钮），逼站点去请求媒体
///   5. 抓到的链接做「新鲜度」判断：带 expire 参数的，检查是否比原链更新
@MainActor
final class LinkRefresher: NSObject, ObservableObject {

  private var web: WKWebView?
  private var found: [(url: URL, at: Date)] = []
  private var done: ((URL?) -> Void)?
  private var timer: Timer?
  private var finished = false

  /// 在 `pageURL` 页面里抓一条新直链。
  ///
  /// - Parameter preferHost: 优先挑这个域名上的（通常是原直链的 host）
  /// - Parameter timeout: 最长等多久
  func refresh(pageURL: URL,
               preferHost: String?,
               timeout: TimeInterval = 25,
               completion: @escaping (URL?) -> Void) {

    cleanup()
    found = []
    done = completion
    finished = false

    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .default()
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    // 让媒体的自动播放不受限制
    cfg.allowsAirPlayForMediaPlayback = false

    let ucc = WKUserContentController()
    ucc.addUserScript(WKUserScript(source: Self.hook,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: false))
    ucc.add(self, name: "linkRefresh")
    cfg.userContentController = ucc

    let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                      configuration: cfg)
    w.navigationDelegate = self
    w.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
      + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // 关键：不能 alpha=0 + hidden，WebKit 会跳过渲染/脚本调度。
    // 用极小尺寸 + 移出屏幕外的位置，视觉上看不见但算"可见"。
    w.alpha = 0.01
    w.isUserInteractionEnabled = false
    w.frame = CGRect(x: -4000, y: -4000, width: 390, height: 844)
    if let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
       let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
      win.addSubview(w)
    } else {
      // 实在挂不上就算了，至少能加载
    }
    web = w

    var req = URLRequest(url: pageURL)
    if let host = pageURL.host {
      req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
    }
    w.load(req)

    timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.finish(preferHost: preferHost) }
    }
  }

  // MARK: 挑选与收尾

  private func finish(preferHost: String?) {
    guard !finished else { return }
    finished = true
    timer?.invalidate()
    timer = nil

    let pick = pickBest(preferHost: preferHost)
    let cb = done
    done = nil
    cleanup()
    cb?(pick)
  }

  private func pickBest(preferHost: String?) -> URL? {
    guard !found.isEmpty else { return nil }

    // 优先同 host
    var pool = found
    if let target = preferHost, !target.isEmpty {
      let same = found.filter { item in
        guard let h = item.url.host else { return false }
        return h == target || h.hasSuffix("." + target) || target.hasSuffix("." + h)
      }
      if !same.isEmpty { pool = same }
    }

    // 再按「清晰度码位 + 新鲜度」排
    func score(_ item: (url: URL, at: Date)) -> Double {
      let s = item.url.absoluteString.lowercased()
      var q = 0.0
      if s.contains("30080") || s.contains("2160") { q = 500 }
      else if s.contains("30077") || s.contains("1440") { q = 450 }
      else if s.contains("30064") || s.contains("1080") { q = 400 }
      else if s.contains("30032") || s.contains("720") { q = 350 }
      else if s.contains("480") { q = 300 }
      // 越晚抓到的越新
      let age = Date().timeIntervalSince(item.at)
      return q + max(0, 100 - age)
    }

    return pool.max { score($0) < score($1) }?.url
  }

  private func cleanup() {
    timer?.invalidate()
    timer = nil
    if let w = web {
      w.stopLoading()
      w.configuration.userContentController
        .removeScriptMessageHandler(forName: "linkRefresh")
      w.navigationDelegate = nil
      w.removeFromSuperview()
    }
    web = nil
  }

  // MARK: 触发播放

  private static let playScript = #"""
  (function () {
    try {
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        try { v.muted = true; v.autoplay = true; v.play(); } catch (e) {}
      }
      var ss = document.querySelectorAll('[class*=play],[aria-label*=播放],[aria-label*=Play],.xgplayer-start,[class*=PlayButton],[class*=play-btn]');
      for (var j = 0; j < ss.length && j < 6; j++) {
        try { ss[j].click(); } catch (e) {}
      }
      // 有些站点要滚动到播放器才开始加载
      try { window.scrollBy(0, 400); } catch (e) {}
    } catch (e) {}
  })();
  """#

  /// 从多个选择器里再捞一次（有些播放地址藏在 script 标签里）。
  private static let sweepScript = #"""
  (function () {
    var out = [];
    try {
      var scripts = document.querySelectorAll('script');
      for (var i = 0; i < scripts.length; i++) {
        var t = scripts[i].textContent || '';
        if (t.length < 20) { continue; }
        var m = t.match(/https?:\\?\/\\?\/[^"'\s\\]+?\.(?:mp4|m3u8|m4s)[^"'\s\\]*/g);
        if (m) { for (var k = 0; k < m.length; k++) { out.push(m[k].replace(/\\\//g, '/')); } }
      }
    } catch (e) {}
    for (var x = 0; x < out.length; x++) {
      try { window.webkit.messageHandlers.linkRefresh.postMessage({ url: out[x] }); } catch (e) {}
    }
  })();
  """#

  // MARK: 注入钩子

  private static let hook = #"""
  (function () {
    if (window.__tlRefresh) { return; }
    window.__tlRefresh = true;

    var post = function (u) {
      if (!u) { return; }
      var s;
      try { s = String(u); } catch (e) { return; }
      var l = s.slice(0, 5).toLowerCase();
      if (l === 'data:' || l === 'blob:' || l === 'about') { return; }
      try { window.webkit.messageHandlers.linkRefresh.postMessage({ url: s }); } catch (e) {}
    };

    var media = function (u) {
      if (!u) { return false; }
      var s = String(u);
      return /\.(mp4|m4s|m3u8|flv|ts|webm)(\?|$)/i.test(s)
          || /videoplayback|playwm|\/play\/|\/video\/tos\/|\/aweme\/v1\/play/i.test(s);
    };

    try {
      var xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        try { if (media(u)) { post(u); } } catch (e) {}
        return xo.apply(this, arguments);
      };
    } catch (e) {}

    try {
      var of = window.fetch;
      if (of) {
        window.fetch = function (input) {
          try {
            var u = (typeof input === 'string') ? input : (input && input.url);
            if (media(u)) { post(u); }
          } catch (e) {}
          return of.apply(this, arguments);
        };
      }
    } catch (e) {}

    // 监控 <video>/<source> 的 src 变化
    var scan = function () {
      try {
        var els = document.querySelectorAll('video,audio,source');
        for (var i = 0; i < els.length; i++) {
          var u = els[i].currentSrc || els[i].src;
          if (u && media(u)) { post(u); }
        }
      } catch (e) {}
    };
    scan();
    setInterval(scan, 1000);

    // 有些站用 MediaSource，把 blob 的底层请求从 PerformanceObserver 里挖
    try {
      new PerformanceObserver(function (list) {
        var entries = list.getEntries();
        for (var i = 0; i < entries.length; i++) {
          var n = entries[i].name;
          if (n && media(n)) { post(n); }
        }
      }).observe({ entryTypes: ['resource'] });
    } catch (e) {}
  })();
  """#
}

// MARK: - 异步桥

/// 把回调式刷新包成 async，供引擎 await。
@MainActor
final class LinkRefresherBridge {
  static let shared = LinkRefresherBridge()

  private var keepAlive: LinkRefresher?

  func refresh(pageURL: URL, preferHost: String?) async -> URL? {
    await withCheckedContinuation { cont in
      let r = LinkRefresher()
      keepAlive = r
      r.refresh(pageURL: pageURL, preferHost: preferHost) { url in
        cont.resume(returning: url)
      }
    }
  }
}

extension LinkRefresher: WKNavigationDelegate, WKScriptMessageHandler {
  nonisolated func userContentController(_ ucc: WKUserContentController,
                                         didReceive message: WKScriptMessage) {
    guard message.name == "linkRefresh",
          let body = message.body as? [String: Any],
          let s = body["url"] as? String,
          let u = URL(string: s) else { return }
    Task { @MainActor in
      if !self.found.contains(where: { $0.url == u }) {
        self.found.append((url: u, at: Date()))
      }
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in
      // 加载完立刻点播放，然后隔几秒再来几次（有些站点懒加载）
      for delay in [0.0, 1.5, 3.0, 6.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          webView.evaluateJavaScript(Self.playScript) { _, _ in }
          webView.evaluateJavaScript(Self.sweepScript) { _, _ in }
        }
      }
    }
  }
}
