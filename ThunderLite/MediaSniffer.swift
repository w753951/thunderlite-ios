import Foundation
import WebKit
import Combine

// MARK: - 资源类型

/// 嗅到的资源分类。
enum MediaKind: String, CaseIterable {
  case image, video, audio

  var title: String {
    switch self {
    case .image: return "图片"
    case .video: return "视频"
    case .audio: return "音频"
    }
  }

  var symbol: String {
    switch self {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "waveform"
    }
  }
}

/// 一条嗅探结果。
struct SniffedMedia: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  let kind: MediaKind
  /// 图片的自然尺寸，或视频的提示尺寸；拿不到就是 nil。
  var pixelSize: String?
  /// 来路：xhr / fetch / src / dom，仅用于调试展示。
  var via: String = ""

  static func == (a: SniffedMedia, b: SniffedMedia) -> Bool { a.url == b.url }

  /// 文件名，用于下载时落盘。
  var suggestedName: String {
    let last = url.lastPathComponent
    if !last.isEmpty, last != "/" { return last }
    let ext: String
    switch kind {
    case .video: ext = "mp4"
    case .audio: ext = "mp3"
    case .image: ext = "jpg"
    }
    return "media-\(Int(Date().timeIntervalSince1970)).\(ext)"
  }

  /// 流媒体清单：能播但没法当普通文件下。
  var isManifest: Bool {
    let p = url.path.lowercased()
    return p.hasSuffix(".m3u8") || p.hasSuffix(".mpd")
  }
}

// MARK: - 嗅探收集器

@MainActor
final class SnifferStore: ObservableObject {
  @Published private(set) var items: [SniffedMedia] = []
  /// 页面里是否有 video 元素，决定是否显示"有视频"提示。
  @Published private(set) var sawVideoTag = false

  private var seen = Set<String>()

  func ingest(_ body: [String: Any]) {
    guard let urlStr = body["url"] as? String,
          let url = URL(string: urlStr),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else { return }

    if let tag = body["tag"] as? String, tag == "video" { sawVideoTag = true }

    guard let kindRaw = body["kind"] as? String,
          let kind = MediaKind(rawValue: kindRaw) else { return }

    // 同一个 URL 只收一次
    let key = url.absoluteString
    guard !seen.contains(key) else { return }
    seen.insert(key)

    var media = SniffedMedia(url: url, kind: kind)
    if let w = body["w"] as? Int, let h = body["h"] as? Int, w > 1, h > 1 {
      media.pixelSize = "\(w)×\(h)"
    }
    if let via = body["via"] as? String { media.via = via }

    items.insert(media, at: 0)
    // 上限防止内存无限涨
    if items.count > 400 {
      let dropped = items.suffix(from: 400)
      for d in dropped { seen.remove(d.url.absoluteString) }
      items = Array(items.prefix(400))
    }
  }

  func items(of kind: MediaKind) -> [SniffedMedia] {
    items.filter { $0.kind == kind }
  }

  func count(of kind: MediaKind) -> Int {
    items.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
  }

  func reset() {
    items.removeAll()
    seen.removeAll()
    sawVideoTag = false
  }
}

// MARK: - 注入脚本

/// 在页面里挂钩 fetch / XHR / 媒体元素属性，并用 MutationObserver 扫 DOM。
///
/// 只挂网络层不够：很多站点的视频地址是拼出来塞进 `<video src>` 的，
/// 从没走过 fetch；只扫 DOM 也不够：m3u8 分片经常是 XHR 拉的，页面上看不到。
/// 两边都做，取并集。
enum SnifferScript {
  static let source = #"""
  (function () {
    if (window.__tlSnifferInstalled) { return; }
    window.__tlSnifferInstalled = true;

    var post = function (kind, url, extra) {
      if (!url) { return; }
      var s;
      try { s = String(url); } catch (e) { return; }
      if (!s) { return; }
      var low = s.slice(0, 5).toLowerCase();
      if (low === 'data:' || low === 'blob:' || low === 'about') { return; }
      var msg = { kind: kind, url: s };
      if (extra) { for (var k in extra) { if (extra[k] !== undefined) { msg[k] = extra[k]; } } }
      try { window.webkit.messageHandlers.tlSniffer.postMessage(msg); } catch (e) {}
    };

    var guess = function (u) {
      if (!u) { return null; }
      var s = String(u).toLowerCase().split('#')[0].split('?')[0];
      if (/\.(m3u8|mpd)$/.test(s)) { return 'video'; }
      if (/\.(mp4|webm|mov|m4v|flv|mkv|ts|ogv)$/.test(s)) { return 'video'; }
      if (/\.(mp3|m4a|aac|ogg|oga|wav|flac|opus)$/.test(s)) { return 'audio'; }
      if (/\.(jpg|jpeg|png|gif|webp|bmp|avif|heic)$/.test(s)) { return 'image'; }
      return null;
    };

    // ── XHR ──
    try {
      var xo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        try { var k = guess(u); if (k) { post(k, u, { via: 'xhr' }); } } catch (e) {}
        return xo.apply(this, arguments);
      };
    } catch (e) {}

    // ── fetch ──
    try {
      var of = window.fetch;
      if (of) {
        window.fetch = function (input) {
          try {
            var u = (typeof input === 'string') ? input : (input && input.url);
            var k = guess(u);
            if (k) { post(k, u, { via: 'fetch' }); }
          } catch (e) {}
          return of.apply(this, arguments);
        };
      }
    } catch (e) {}

    // ── 媒体元素的 src setter ──
    try {
      var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (d && d.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'src', {
          configurable: true,
          get: d.get,
          set: function (v) {
            try {
              var k = guess(v) || (this.tagName === 'AUDIO' ? 'audio' : 'video');
              post(k, v, { via: 'src', tag: this.tagName.toLowerCase() });
            } catch (e) {}
            return d.set.call(this, v);
          }
        });
      }
    } catch (e) {}

    // ── DOM 扫描 ──
    var scan = function () {
      try {
        var vids = document.querySelectorAll('video');
        for (var i = 0; i < vids.length; i++) {
          var el = vids[i];
          var u = el.currentSrc || el.src;
          if (!u && el.querySelector) {
            var so = el.querySelector('source');
            if (so) { u = so.src; }
          }
          if (u) {
            post(guess(u) || 'video', u, {
              via: 'dom', tag: 'video',
              w: el.videoWidth || undefined,
              h: el.videoHeight || undefined
            });
          }
        }
        var auds = document.querySelectorAll('audio');
        for (var j = 0; j < auds.length; j++) {
          var a = auds[j];
          var au = a.currentSrc || a.src;
          if (au) { post(guess(au) || 'audio', au, { via: 'dom', tag: 'audio' }); }
        }
        var imgs = document.querySelectorAll('img');
        for (var k = 0; k < imgs.length; k++) {
          var im = imgs[k];
          var iu = im.currentSrc || im.src;
          if (iu) {
            post(guess(iu) || 'image', iu, {
              via: 'dom', tag: 'img',
              w: im.naturalWidth || undefined,
              h: im.naturalHeight || undefined
            });
          }
        }
        // picture > source
        var srcs = document.querySelectorAll('source[src]');
        for (var m = 0; m < srcs.length; m++) {
          var su = srcs[m].src;
          var sk = guess(su);
          if (sk) { post(sk, su, { via: 'dom', tag: 'source' }); }
        }
      } catch (e) {}
    };

    scan();
    document.addEventListener('DOMContentLoaded', scan);
    window.addEventListener('load', scan);
    setInterval(scan, 1500);

    try {
      new MutationObserver(function () { scan(); })
        .observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
  })();
  """#
}

// MARK: - 常用站点

/// 首页快捷入口。
struct SniffHomeSite: Identifiable {
  let id = UUID()
  let name: String
  let url: String
  let tint: UInt32
}

enum SniffHome {
  static let sites: [SniffHomeSite] = [
    .init(name: "Bilibili", url: "https://m.bilibili.com", tint: 0xFB7299),
    .init(name: "YouTube", url: "https://m.youtube.com", tint: 0xFF0033),
    .init(name: "微博视频", url: "https://m.weibo.cn", tint: 0xE6162D),
    .init(name: "抖音", url: "https://www.douyin.com", tint: 0x00F2EA),
    .init(name: "Pixiv", url: "https://www.pixiv.net", tint: 0x0096FA),
    .init(name: "Twitter", url: "https://mobile.twitter.com", tint: 0x1D9BF0),
    .init(name: "小红书", url: "https://www.xiaohongshu.com", tint: 0xFF2442),
    .init(name: "Vimeo", url: "https://vimeo.com", tint: 0x1AB7EA),
  ]
}
