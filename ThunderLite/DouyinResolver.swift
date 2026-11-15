import Foundation

// MARK: - 分享文本解析

/// 从「抖音口令 / 分享文案」这类混杂文本里把真正的链接抠出来。
///
/// 典型输入：
/// `0.74 复制打开抖音，看看【可爱小刘的作品】愿人生常驻... https://v.douyin.com/ObU9pgXXPQM/ 05/08 ndn:/ N@w.sR :1pm`
///
/// 要抓的是 `https://v.douyin.com/ObU9pgXXPQM/`，其余全是噪音。
enum ShareTextParser {

  /// 从任意文本里找出第一个可用 URL。
  ///
  /// 优先认带协议的；没有协议时，按「像域名的 token」兜底。
  static func extractURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // 1) 先把带 http(s):// 的挑出来
    if let r = trimmed.range(of: #"https?://[^\s\u{3000}，,。；;"'<>【】（）()]+"#,
                             options: .regularExpression) {
      var raw = String(trimmed[r])
      // 去掉尾部的标点，这些经常被中文句读粘上来
      raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?、。，；：！？)]}>\"'"))
      if let u = URL(string: raw) { return u }
    }

    // 2) 没有协议：找形如 xxx.yy/zzz 的 token
    if let r = trimmed.range(of: #"[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}(/[^\s\u{3000}，,。；;]*)?[^\s\u{3000}，,。；;]*"#,
                             options: .regularExpression) {
      var raw = String(trimmed[r])
      raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?、。，；：！？)]}>\"'"))
      if let u = URL(string: "https://" + raw) { return u }
    }

    return nil
  }

  /// 文本里是否还残留口令特征（用于判断"这是分享文案，不是纯链接"）。
  static func looksLikeShareText(_ text: String) -> Bool {
    let t = text
    if t.contains("复制打开") || t.contains("复制此链接") { return true }
    if t.contains("#") && t.contains("http") { return true }
    let digits = t.filter { $0.isNumber }.count
    return digits > 10 && t.count > 40
  }
}

// MARK: - 短链展开

/// 把 v.douyin.com 这类短链跟到真实地址。
///
/// 短链本身不会返回视频，必须先拿到重定向后的详情页 URL，
/// 里面的 video id 才能拿去请求播放地址。
enum ShortLinkResolver {

  /// 跟随重定向，返回最终 URL。最多跟 8 跳。
  static func resolve(_ url: URL, completion: @escaping (URL?) -> Void) {
    resolve(url, hops: 0, completion: completion)
  }

  private static func resolve(_ url: URL, hops: Int,
                              completion: @escaping (URL?) -> Void) {
    guard hops < 8 else { completion(url); return }

    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "GET"
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpShouldSetCookies = false
    cfg.timeoutIntervalForRequest = 15
    let session = URLSession(configuration: cfg)

    // 用 GET 而不是 HEAD：不少短链服务对 HEAD 不返回 Location
    let task = session.dataTask(with: req) { data, resp, err in
      guard let http = resp as? HTTPURLResponse else {
        completion(url); return
      }

      // 3xx：跟 Location
      if (300...399).contains(http.statusCode) {
        if let locStr = http.value(forHTTPHeaderField: "Location"),
           let loc = URL(string: locStr, relativeTo: url)?.absoluteURL {
          resolve(loc, hops: hops + 1, completion: completion)
          return
        }
        // 没有 Location 却有 data，继续往下扒 HTML
      }

      // 200：看最终 URL 有没有变（URLSession 会自己跟一部分）
      if let finalURL = http.url, finalURL.absoluteString != url.absoluteString {
        completion(finalURL)
        return
      }

      // 还不行就从 HTML 里找 canonical / 跳转脚本
      if let data, let html = String(data: data, encoding: .utf8) {
        if let found = extractFromHTML(html) {
          completion(found)
          return
        }
      }

      completion(url)
    }
    task.resume()
  }

  /// 从 HTML 里挑出真正的详情页地址。
  private static func extractFromHTML(_ html: String) -> URL? {
    // <link rel="canonical" href="...">
    for pattern in [
      #"<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']"#,
      #"<meta[^>]+property=["']og:url["'][^']*["'][^>]+content=["']([^"']+)["']"#,
    ] {
      if let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
        let seg = String(html[r])
        if let hr = seg.range(of: #"https?://[^"']+"#, options: .regularExpression),
           let u = URL(string: String(seg[hr])) {
          return u
        }
      }
    }
    // location.replace("...")
    if let r = html.range(of: #"location\.(?:replace|href)\s*=\s*["']([^"']+)["']"#,
                          options: .regularExpression) {
      let seg = String(html[r])
      if let hr = seg.range(of: #"https?://[^"']+"#, options: .regularExpression),
         let u = URL(string: String(seg[hr])) {
        return u
      }
    }
    return nil
  }
}

// MARK: - 抖音解析

/// 抖音图文/视频解析：拿到无水印直链。
///
/// 流程：
///   1. 分享文案 → 抠出 v.douyin.com 短链
///   2. 短链跟重定向 → 详情页 URL，里面带 video id / modal_id
///   3. 请求抖音的 iteminfo 接口（或解析页面内嵌 JSON）→ 播放地址
///
/// 抖音换过几次接口，所以这里给了两条路：先试接口，失败再扒页面里的
/// `RENDER_DATA` / `__INITIAL_STATE__`。
enum DouyinResolver {

  struct Result {
    let title: String
    /// 无水印直链，可能有多个清晰度。
    let playURLs: [URL]
    /// 封面 / 图集的图片。
    let imageURLs: [URL]
    let author: String
    let isImagePost: Bool
  }

  enum DouyinError: LocalizedError {
    case notDouyinLink
    case resolveFailed(String)
    case noMedia

    var errorDescription: String? {
      switch self {
      case .notDouyinLink: return "不是抖音链接。"
      case .resolveFailed(let s): return s
      case .noMedia: return "没解析到可下载的媒体，可能需要登录或链接已失效。"
      }
    }
  }

  static func isDouyin(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host.contains("douyin.com") || host.contains("iesdouyin.com")
  }

  /// 从任意文本解析出抖音媒体。
  static func resolve(from text: String,
                      completion: @escaping (Swift.Result<DouyinResolver.Result, Error>) -> Void) {
    guard let url = ShareTextParser.extractURL(from: text) else {
      completion(.failure(DouyinError.resolveFailed("文本里没找到链接。")))
      return
    }
    guard isDouyin(url) else {
      completion(.failure(DouyinError.notDouyinLink))
      return
    }

    // 已经是详情页就直接用，短链才需要跟
    if url.path.contains("/video/") || url.path.contains("/note/")
        || url.query?.contains("modal_id") == true {
      fetchItem(from: url, completion: completion)
      return
    }

    ShortLinkResolver.resolve(url) { finalURL in
      guard let finalURL else {
        completion(.failure(DouyinError.resolveFailed("短链展开失败。")))
        return
      }
      fetchItem(from: finalURL, completion: completion)
    }
  }

  /// 从详情页 URL 里取 item id。
  static func itemID(from url: URL) -> String? {
    let path = url.path
    // /video/7300000000000000000
    for key in ["/video/", "/note/", "/share/video/"] {
      if let r = path.range(of: key) {
        let rest = String(path[r.upperBound...])
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty { return String(digits) }
      }
    }
    // ?modal_id=7300000000000000000
    if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let v = comps.queryItems?.first(where: { $0.name == "modal_id" })?.value,
       !v.isEmpty {
      return v
    }
    return nil
  }

  // MARK: 接口 → 页面降级

  private static func fetchItem(from url: URL,
                                completion: @escaping (Swift.Result<DouyinResolver.Result, Error>) -> Void) {
    guard let id = itemID(from: url) else {
      // 没有 id 就只能扒页面
      scrapePage(url, completion: completion)
      return
    }

    // 接口一：老版 iteminfo（很多情况下仍可用）
    let api = "https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/?item_ids=\(id)"
    if let apiURL = URL(string: api) {
      requestJSON(apiURL) { json in
        if let json, let result = parseItemInfo(json) {
          completion(.success(result))
          return
        }
        // 接口二：扒页面里的内嵌 JSON
        scrapePage(url, completion: completion)
      }
    } else {
      scrapePage(url, completion: completion)
    }
  }

  private static func requestJSON(_ url: URL, completion: @escaping ([String: Any]?) -> Void) {
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")

    URLSession.shared.dataTask(with: req) { data, _, _ in
      guard let data,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      DispatchQueue.main.async { completion(obj) }
    }.resume()
  }

  /// 解析 iteminfo 接口返回。
  private static func parseItemInfo(_ json: [String: Any]) -> Result? {
    guard let list = json["item_list"] as? [[String: Any]],
          let first = list.first else { return nil }

    let title = (first["desc"] as? String) ?? "抖音视频"
    let author = ((first["author"] as? [String: Any])?["nickname"] as? String) ?? ""

    var playURLs: [URL] = []
    var imageURLs: [URL] = []

    // 视频
    if let video = first["video"] as? [String: Any] {
      // play_addr 是带水印的，但 url_list 里第一个常常就是无水印源
      for key in ["play_addr", "play_addr_h264", "download_addr"] {
        if let addr = video[key] as? [String: Any],
           let list = addr["url_list"] as? [String] {
          for s in list {
            // 把 playwm 换成 play 是社区常用的去水印手法
            let cleaned = s.replacingOccurrences(of: "/playwm/", with: "/play/")
            if let u = URL(string: cleaned), !playURLs.contains(u) {
              playURLs.append(u)
            }
          }
        }
      }
      if let cover = video["cover"] as? [String: Any],
         let list = cover["url_list"] as? [String], let s = list.first,
         let u = URL(string: s) {
        imageURLs.append(u)
      }
    }

    // 图集
    if let images = first["images"] as? [[String: Any]] {
      for img in images {
        if let list = img["url_list"] as? [String], let s = list.first,
           let u = URL(string: s) {
          imageURLs.append(u)
        }
      }
    }

    guard !playURLs.isEmpty || !imageURLs.isEmpty else { return nil }
    return Result(title: title, playURLs: playURLs, imageURLs: imageURLs,
                  author: author, isImagePost: playURLs.isEmpty)
  }

  /// 扒详情页里内嵌的 JSON（RENDER_DATA / __INITIAL_STATE__）。
  private static func scrapePage(_ url: URL,
                                 completion: @escaping (Swift.Result<DouyinResolver.Result, Error>) -> Void) {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: req) { data, _, err in
      guard let data, let html = String(data: data, encoding: .utf8) else {
        DispatchQueue.main.async {
          completion(.failure(DouyinError.resolveFailed(
            err?.localizedDescription ?? "页面读取失败。")))
        }
        return
      }

      // 直接在 HTML 里找 playAddr / url_list 的痕迹
      var playURLs: [URL] = []
      let pattern = #"https?:\\?/\\?/[^"'\s]+?\.(?:mp4|m3u8)[^"'\s]*"#
      if let re = try? NSRegularExpression(pattern: pattern) {
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for m in matches.prefix(30) {
          var s = ns.substring(with: m.range)
          s = s.replacingOccurrences(of: "\\/", with: "/")
          s = s.replacingOccurrences(of: "/playwm/", with: "/play/")
          if let u = URL(string: s), !playURLs.contains(u) {
            playURLs.append(u)
          }
        }
      }

      // 标题
      var title = "抖音视频"
      if let r = html.range(of: #"<title>([^<]+)</title>"#, options: .regularExpression) {
        let seg = String(html[r])
        title = seg
          .replacingOccurrences(of: "<title>", with: "")
          .replacingOccurrences(of: "</title>", with: "")
      }
      if let r = html.range(of: #""desc":"([^"]{4,120})""#, options: .regularExpression) {
        let seg = String(html[r])
        let cleaned = seg
          .replacingOccurrences(of: "\"desc\":\"", with: "")
          .replacingOccurrences(of: "\"", with: "")
        if !cleaned.isEmpty { title = cleaned }
      }

      DispatchQueue.main.async {
        if playURLs.isEmpty {
          completion(.failure(DouyinError.noMedia))
        } else {
          completion(.success(Result(title: title, playURLs: playURLs,
                                     imageURLs: [], author: "", isImagePost: false)))
        }
      }
    }.resume()
  }
}
