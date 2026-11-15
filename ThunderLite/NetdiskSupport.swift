import Foundation

/// 一家网盘的接入参数。
struct NetdiskSite {
  let key: String
  let name: String
  /// 该网盘 CDN 校验的 Referer（用来补 Origin 与 Sec-Fetch-*）。
  let referer: String
  /// 域名匹配片段。
  let patterns: [String]
  /// 该网盘的并发上限：超过会被限速甚至 412 风控。
  let maxThreads: Int
  /// 是否带用户填的 Cookie。
  ///
  /// 夸克和 UC 是反例：实测带登录 Cookie 反而被按「账号」限速到 ~130 KB/s，
  /// 丢掉 Cookie 用匿名 UA 才能跑满。其余网盘强校验 Cookie，必须原样带上。
  let sendCookie: Bool
  /// 界面用色。
  let color: UInt32

  var origin: String {
    guard let u = URL(string: referer),
          let scheme = u.scheme, let host = u.host else { return referer }
    return "\(scheme)://\(host)"
  }
}

/// 网盘识别与请求头补全。
///
/// 从 thunder-lite 的 netdisk.js 移植：那里积累的是实测经验值 ——
/// 哪家必须带 Referer、哪家带了 Cookie 反而被限速、哪家并发开高了会被风控。
enum NetdiskSupport {
  /// 各家网盘的真实 UA。手机端用桌面 UA：多数网盘 CDN 对移动 UA 更严格。
  static let defaultUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  static let sites: [NetdiskSite] = [
    .init(key: "quark", name: "夸克网盘", referer: "https://pan.quark.cn/",
          patterns: ["quark.cn"], maxThreads: 32, sendCookie: false, color: 0x3D7EFF),
    .init(key: "uc", name: "UC 网盘", referer: "https://drive.uc.cn/",
          patterns: ["uc.cn"], maxThreads: 32, sendCookie: false, color: 0xFF7A2F),
    .init(key: "baidu", name: "百度网盘", referer: "https://pan.baidu.com/",
          patterns: ["baidu.com", "baidupcs.com", "bdstatic.com", "baidubce.com"],
          maxThreads: 8, sendCookie: true, color: 0x2D6CDF),
    .init(key: "ali", name: "阿里云盘", referer: "https://www.alipan.com/",
          patterns: ["alipan.com", "aliyundrive.com", "aliyundrive.net",
                     "alicloudccp.com", "aliyuncs.com"],
          maxThreads: 4, sendCookie: true, color: 0x6B4EF5),
    .init(key: "pan123", name: "123 云盘", referer: "https://www.123pan.com/",
          patterns: ["123pan.com", "123684.com", "123865.com", "123912.com"],
          maxThreads: 16, sendCookie: true, color: 0x1FA97A),
    .init(key: "xunlei", name: "迅雷云盘", referer: "https://pan.xunlei.com/",
          patterns: ["xunlei.com", "xunlei.cn", "xunleix.com"],
          maxThreads: 8, sendCookie: true, color: 0x2F80ED),
    .init(key: "tianyi", name: "天翼云盘", referer: "https://cloud.189.cn/",
          patterns: ["189.cn"], maxThreads: 8, sendCookie: true, color: 0x1E88E5),
    .init(key: "yidong", name: "移动云盘", referer: "https://yun.139.com/",
          patterns: ["139.com"], maxThreads: 8, sendCookie: true, color: 0x0091FF),
  ]

  /// 分享页正则：这些链接是网页而不是直链，下不了。
  private static let sharePatterns: [(name: String, pattern: String)] = [
    ("夸克网盘", #"^https?://pan\.quark\.cn/s/"#),
    ("百度网盘", #"^https?://pan\.baidu\.com/s/"#),
    ("阿里云盘", #"^https?://(?:www\.)?(?:alipan|aliyundrive)\.com/s/"#),
    ("UC 网盘", #"^https?://drive\.uc\.cn/s/"#),
    ("123 云盘", #"^https?://(?:www\.)?123pan\.com/s/"#),
    ("迅雷云盘", #"^https?://pan\.xunlei\.com/s/"#),
    ("天翼云盘", #"^https?://cloud\.189\.cn/(?:t|web/share)"#),
    ("移动云盘", #"^https?://yun\.139\.com/(?:share|web/share)"#),
  ]

  /// 命中分享页时返回网盘名，否则 nil。
  static func sharePageName(_ url: String) -> String? {
    let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
    for item in sharePatterns where text.range(of: item.pattern, options: .regularExpression) != nil {
      return item.name
    }
    return nil
  }

  /// 按域名认出是哪家网盘。
  static func site(for url: String) -> NetdiskSite? {
    guard let host = URL(string: url)?.host?.lowercased() else { return nil }
    for site in sites {
      for pattern in site.patterns where host == pattern
        || host.hasSuffix("." + pattern) || host.contains(pattern) {
        return site
      }
    }
    return nil
  }

  struct Resolved {
    let url: String
    let site: NetdiskSite?
    let headers: [String: String]
  }

  /// 为一次下载拼出完整请求头。
  ///
  /// - Parameter extra: 用户手动补充的头，优先级最高（能覆盖默认值）。
  /// - Parameter cookie: 用户为该网盘填的 Cookie；按 `sendCookie` 决定要不要带。
  static func resolve(url: String, extra: [String: String] = [:],
                      cookie: String? = nil, ua: String? = nil) -> Resolved {
    let site = site(for: url)
    var headers: [String: String] = [
      "User-Agent": ua ?? defaultUA,
      "Accept": "*/*",
      "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    ]

    if let site {
      let ref = site.referer.hasSuffix("/") ? site.referer : site.referer + "/"
      headers["Referer"] = ref
      headers["Origin"] = site.origin
      // 这几项缺一个，夸克一类 CDN 会直接 403 / 412。
      headers["Sec-Fetch-Dest"] = "empty"
      headers["Sec-Fetch-Mode"] = "cors"
      headers["Sec-Fetch-Site"] = "same-site"

      if site.sendCookie, let cookie, !cookie.isEmpty {
        headers["Cookie"] = cookie
      }
    }

    for (key, value) in extra where !key.isEmpty && !value.isEmpty {
      headers[key] = value
    }
    headers.removeValue(forKey: "Range")   // Range 由引擎按段生成
    return Resolved(url: url, site: site, headers: headers)
  }

  /// 该链接建议的并发数；认不出网盘时给用户设的上限。
  static func recommendedThreads(_ url: String) -> Int? {
    site(for: url)?.maxThreads
  }

  /// 常见的 HTTP 状态码给出可操作的解释。
  static func hint(for status: Int) -> String {
    switch status {
    case 400:
      return "链接无效或已过期（网盘直链通常几分钟就失效），也可能缺少 Cookie 或 UA。"
    case 401, 403:
      return "链接已过期、需要登录，或被 CDN 拒绝；请确认 Referer 与 Cookie。"
    case 404:
      return "文件不存在或已被删除。"
    case 412:
      return "被网盘风控拦截；请补充该网盘的 Cookie 后再试。"
    case 429:
      return "请求太频繁被限流；把线程数调低再试。"
    default:
      return "请求被服务器拒绝。"
    }
  }
}
