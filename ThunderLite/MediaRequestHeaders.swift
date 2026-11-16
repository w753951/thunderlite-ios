import Foundation
import WebKit

// MARK: - 站点 Cookie 抓取

/// 从 WKWebsiteDataStore 里捞出某个 URL 对应的 Cookie 并拼成请求头。
///
/// 为什么需要：抖音、B 站、微博的 CDN 除了校验 Referer，还会校验会话 Cookie。
/// 预览能播是因为 AVPlayer 用的是系统网络栈 + 页面上已经建立的会话；
/// 而下载引擎是独立的 URLSession，不带 Cookie 就会被 403。
enum SiteCookies {

  /// 取该 URL 适用的 Cookie 字符串（同步版，会阻塞到取完）。
  ///
  /// WebKit 的接口是异步回调，这里用信号量转同步。只在后台线程调用。
  static func headerString(for url: URL) -> String? {
    var result: String?
    let sem = DispatchSemaphore(value: 0)

    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let matched = cookies.filter { cookie in
        // 域名匹配：host 以 cookie.domain 结尾（cookie.domain 可能带前导点）
        guard let host = url.host?.lowercased() else { return false }
        let d = cookie.domain.lowercased().hasPrefix(".")
          ? String(cookie.domain.lowercased().dropFirst())
          : cookie.domain.lowercased()
        let domainOK = host == d || host.hasSuffix("." + d)
        guard domainOK else { return false }

        // 路径匹配
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
      }

      if !matched.isEmpty {
        result = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      }
      sem.signal()
    }

    _ = sem.wait(timeout: .now() + 3)
    return result
  }

  /// 同步等待版，带超时保护。
  static func cookieHeader(for url: URL) -> String? {
    headerString(for: url)
  }
}

// MARK: - 请求头构建

/// 给任意媒体 URL 拼一套「能过 CDN」的请求头。
enum MediaRequestHeaders {

  static func build(for url: URL,
                    extra: [String: String] = [:]) -> [String: String] {
    var h = extra

    // UA：必须像浏览器，不能是 App 自己的标识
    if h["User-Agent"] == nil {
      h["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    // Referer：按域名映射
    if h["Referer"] == nil {
      h["Referer"] = referer(for: url)
    }

    // Origin：和 Referer 同源（部分 CDN 校验）
    if h["Origin"] == nil, let host = url.host {
      if let ref = h["Referer"],
         let refURL = URL(string: ref),
         let refScheme = refURL.scheme,
         let refHost = refURL.host {
        h["Origin"] = "\(refScheme)://\(refHost)"
      }
      _ = host
    }

    // Cookie：从 WebView 会话里捞
    if h["Cookie"] == nil, let c = SiteCookies.cookieHeader(for: url) {
      h["Cookie"] = c
    }

    if h["Accept"] == nil {
      h["Accept"] = "*/*"
    }
    if h["Accept-Language"] == nil {
      h["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8"
    }
    // 有些 CDN 用 Range 判断是不是播放器请求
    if h["Accept-Encoding"] == nil {
      h["Accept-Encoding"] = "identity"
    }

    return h
  }

  static func referer(for url: URL) -> String {
    guard let host = url.host?.lowercased() else { return "" }

    if host.contains("bilibili") || host.contains("hdslb") || host.contains("bilivideo") {
      return "https://www.bilibili.com/"
    }
    if host.contains("douyin") || host.contains("douyinvod") || host.contains("byteimg")
        || host.contains("bytedance") || host.contains("zjcdn") || host.contains("snssdk")
        || host.contains("mountain") || host.contains("ixigua") {
      return "https://www.douyin.com/"
    }
    if host.contains("weibo") || host.contains("sinaimg") || host.contains("weibocdn") {
      return "https://weibo.com/"
    }
    if host.contains("xiaohongshu") || host.contains("xhscdn") {
      return "https://www.xiaohongshu.com/"
    }
    if host.contains("youtube") || host.contains("googlevideo") {
      return "https://www.youtube.com/"
    }
    if host.contains("pixiv") || host.contains("pximg") {
      return "https://www.pixiv.net/"
    }
    if host.contains("qq.com") || host.contains("gtimg") || host.contains("qpic") {
      return "https://www.qq.com/"
    }
    if host.contains("kuaishou") || host.contains("gifshow") {
      return "https://www.kuaishou.com/"
    }
    if host.contains("ixigua") {
      return "https://www.ixigua.com/"
    }

    // 兜底：用根域
    let parts = host.split(separator: ".")
    if parts.count >= 2 {
      return "https://\(parts.suffix(2).joined(separator: "."))/"
    }
    return "https://\(host)/"
  }
}
