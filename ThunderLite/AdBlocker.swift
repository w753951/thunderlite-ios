import Foundation
import WebKit

// MARK: - 广告拦截

/// 广告拦截规则：基于 WebKit Content Blocker + 注入脚本双保险。
///
/// Content Blocker 是系统级的，性能最好，但它只能按 URL 匹配资源请求；
/// 页面内 JS 动态插入的浮层、弹窗拦不住，所以再补一段注入脚本兜底。
enum AdBlocker {
  /// 常见广告/统计/追踪域名。只留高置信度的，避免误杀正常资源。
  static let blockedHosts: [String] = [
    // 通用广告网络
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "adservice.google.com", "pagead2.googlesyndication.com",
    "adnxs.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com",
    "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
    "moatads.com", "serving-sys.com", "smartadserver.com",
    "casalemedia.com", "openx.net", "yieldmo.com", "sharethrough.com",
    "3lift.com", "teads.tv", "adform.net", "adsafeprotected.com",
    "amazon-adsystem.com", "media.net", "mgid.com", "zedo.com",

    // 国内常见
    "cpro.baidu.com", "pos.baidu.com", "cbjs.baidu.com",
    "gdt.qq.com", "e.qq.com", "ad.qq.com",
    "tanx.com", "alimama.com", "mmstat.com",
    "cpro.baidustatic.com", "dup.baidustatic.com",

    // 统计/追踪
    "google-analytics.com", "googletagmanager.com", "googletagservices.com",
    "hm.baidu.com", "cnzz.com", "umeng.com", "talkingdata.com",
    "hotjar.com", "mixpanel.com", "segment.io", "amplitude.com",
    "scorecardresearch.com", "quantserve.com", "chartbeat.com",
    "adsby.bidgear.com", "bidgear.com",

    // 弹窗/跳转
    "popads.net", "popcash.net", "propellerads.com", "onclickads.net",
    "clickadu.com", "hilltopads.net", "adsterra.com",
  ]

  /// 可以被放行的"可接受广告"域名（非侵入式）。
  static let acceptableHosts: [String] = [
    "adchoices", "carbonads.com", "ethicalads.io",
  ]

  /// 从域名列表拼出 WebKit content blocker 规则。
  ///
  /// 用 `url-filter` 的 host 锚点匹配，比正则跑 js 高效得多。
  static func rulesJSON(allowAcceptable: Bool) -> String {
    var rules: [[String: Any]] = []

    for host in blockedHosts {
      let escaped = host.replacingOccurrences(of: ".", with: "\\.")
      rules.append([
        "trigger": [
          "url-filter": "^https?://([^/]*\\.)?" + escaped + "[:/]",
          "resource-type": ["image", "script", "style-sheet", "font",
                            "raw", "svg-document", "media", "popup"],
        ],
        "action": ["type": "block"],
      ])
    }

    // 放行可接受广告：优先级靠后，但 WebKit 里 block 一旦命中就不再看后面，
    // 所以这里用 ignore-previous-rules 显式放行。
    if allowAcceptable {
      for host in acceptableHosts {
        let escaped = host.replacingOccurrences(of: ".", with: "\\.")
        rules.append([
          "trigger": ["url-filter": escaped],
          "action": ["type": "ignore-previous-rules"],
        ])
      }
    }

    // 通用广告位路径（保守，只匹配明显特征）
    rules.append([
      "trigger": [
        "url-filter": ".*/(ads?|adserver|advert)/.*\\.(js|gif|png|jpg)",
        "resource-type": ["script", "image"],
      ],
      "action": ["type": "block"],
    ])

    guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
          let json = String(data: data, encoding: .utf8) else {
      return "[]"
    }
    return json
  }

  /// 编译并装载规则。返回是否成功。
  static func compile(allowAcceptable: Bool,
                      completion: @escaping (Bool) -> Void) {
    let json = rulesJSON(allowAcceptable: allowAcceptable)
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "thunderlite-adblock-v1",
      encodedContentRuleList: json
    ) { list, error in
      DispatchQueue.main.async {
        cachedList = list
        completion(error == nil && list != nil)
      }
    }
  }

  /// 编译好的规则缓存，供 webview 配置使用。
  private(set) static var cachedList: WKContentRuleList?

  /// 页面内兜底脚本：干掉常见广告浮层、拦截 window.open 弹窗。
  static let pageScript = #"""
  (function () {
    if (window.__tlAdBlockInstalled) { return; }
    window.__tlAdBlockInstalled = true;

    // 拦截弹窗（很多站点的广告就是靠 window.open 弹的）
    try {
      var ow = window.open;
      window.open = function () {
        try { window.webkit.messageHandlers.tlAdBlock.postMessage('popup'); } catch (e) {}
        return null;
      };
    } catch (e) {}

    // 常见广告容器的选择器
    var SEL = [
      '[id*="google_ads"]', '[id*="div-gpt-ad"]', '[class*="adsbygoogle"]',
      '[id*="BAIDU_SSP"]', '[class*="ad-banner"]', '[class*="ad-container"]',
      '[class*="ad-wrapper"]', '[class*="advert"]', '[id*="advert"]',
      '[class*="sponsor"]', '[class*="popup-ad"]', '[class*="interstitial"]',
      '[class*="overlay-ad"]', '.adsbygoogle', '.ad-slot', '.ad-unit',
      'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
      'iframe[src*="cpro.baidu"]', 'iframe[src*="tanx"]'
    ].join(',');

    var killed = 0;
    var clean = function () {
      try {
        var els = document.querySelectorAll(SEL);
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (el && el.parentNode && el.dataset.tlAdKilled !== '1') {
            el.dataset.tlAdKilled = '1';
            el.style.setProperty('display', 'none', 'important');
            el.style.setProperty('visibility', 'hidden', 'important');
            el.style.setProperty('pointer-events', 'none', 'important');
            killed++;
          }
        }
        // 全屏遮罩类浮层：position fixed + 高 z-index + 面积巨大
        var all = document.body ? document.body.querySelectorAll('div') : [];
        for (var j = 0; j < all.length && j < 2500; j++) {
          var d = all[j];
          if (d.dataset.tlAdKilled === '1') { continue; }
          var cs = getComputedStyle(d);
          if (cs.position === 'fixed' && parseInt(cs.zIndex || '0', 10) > 9000) {
            var r = d.getBoundingClientRect();
            if (r.width > innerWidth * 0.8 && r.height > innerHeight * 0.5) {
              d.dataset.tlAdKilled = '1';
              d.style.setProperty('display', 'none', 'important');
              killed++;
            }
          }
        }
        if (killed > 0) {
          try { window.webkit.messageHandlers.tlAdBlock.postMessage({ count: killed }); } catch (e) {}
        }
      } catch (e) {}
    };

    clean();
    document.addEventListener('DOMContentLoaded', clean);
    setInterval(clean, 1200);
  })();
  """#
}

// MARK: - 拦截计数

@MainActor
final class AdBlockStore: ObservableObject {
  static let shared = AdBlockStore()

  @Published private(set) var blockedCount: Int = 0
  @Published private(set) var popupsBlocked: Int = 0

  private init() {
    blockedCount = UserDefaults.standard.integer(forKey: "adblock.count")
    popupsBlocked = UserDefaults.standard.integer(forKey: "adblock.popups")
  }

  func record(_ body: Any) {
    if let n = body as? Int {
      blockedCount += n
    } else if let dict = body as? [String: Any],
              let n = dict["count"] as? Int {
      blockedCount += n
    } else if let s = body as? String, s == "popup" {
      popupsBlocked += 1
    }
    persist()
  }

  func reset() {
    blockedCount = 0
    popupsBlocked = 0
    persist()
  }

  private func persist() {
    UserDefaults.standard.set(blockedCount, forKey: "adblock.count")
    UserDefaults.standard.set(popupsBlocked, forKey: "adblock.popups")
  }
}
