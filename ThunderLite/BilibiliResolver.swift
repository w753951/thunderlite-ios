import Foundation

// MARK: - 通用视频页解析

/// 处理 b23.tv / bilibili.com、youtube、微博这类"分享链接指向一个网页"的情况。
///
/// 和抖音那条路不同：这些站点的播放地址需要走各自的接口，
/// 这里统一做法是先展开短链拿到页面，再按站点分派。
enum VideoPageResolver {

  enum Site {
    case bilibili, douyin, youtube, weibo, unknown
  }

  static func site(for url: URL) -> Site {
    guard let host = url.host?.lowercased() else { return .unknown }
    if host.contains("b23.tv") || host.contains("bilibili.com")
        || host.contains("biliapi") { return .bilibili }
    if host.contains("douyin.com") || host.contains("iesdouyin.com") { return .douyin }
    if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
    if host.contains("weibo.com") || host.contains("weibo.cn") { return .weibo }
    return .unknown
  }

  /// 统一入口：把分享文本变成可直接下载的媒体地址列表。
  static func resolve(from text: String,
                      completion: @escaping (Swift.Result<MediaBundle, Error>) -> Void) {
    guard let url = ShareTextParser.extractURL(from: text) else {
      completion(.failure(ResolveError.noLink))
      return
    }

    switch site(for: url) {
    case .douyin:
      DouyinResolver.resolve(from: text) { result in
        switch result {
        case .success(let r):
          completion(.success(MediaBundle(
            title: r.title, author: r.author,
            videos: r.playURLs, images: r.imageURLs,
            siteName: "抖音")))
        case .failure(let e):
          completion(.failure(e))
        }
      }
    case .bilibili:
      BilibiliResolver.resolve(from: text, completion: completion)

    default:
      completion(.failure(ResolveError.unsupported(
        url.host ?? "该站点")))
    }
  }
}

/// 统一的结果结构。
struct MediaBundle {
  let title: String
  let author: String
  let videos: [URL]
  let images: [URL]
  let siteName: String
}

enum ResolveError: LocalizedError {
  case noLink
  case unsupported(String)
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .noLink: return "这段文字里没找到链接。"
    case .unsupported(let h): return "暂不支持解析 \(h) 的页面，可以试试粘贴直链。"
    case .failed(let s): return s
    }
  }
}

// MARK: - 哔哩哔哩

/// B 站解析：b23.tv 短链 → BV 号 → playurl 接口 → durl / dash 直链。
///
/// 关键点：
///   - 必须带 Referer: https://www.bilibili.com/，否则 CDN 返回 403
///   - 不带 Referer 下载下来的 mp4 会"能下不能播"
///   - 高清晰度需要登录 Cookie，未登录最高 480P
enum BilibiliResolver {

  /// b23.tv 短链 → 完整 URL。
  static func expand(_ url: URL, completion: @escaping (URL?) -> Void) {
    ShortLinkResolver.resolve(url) { final in
      completion(final)
    }
  }

  /// 从 URL 里抠出 BV 号 / av 号。
  static func videoID(from url: URL) -> String? {
    let s = url.absoluteString
    if let r = s.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) {
      return String(s[r])
    }
    if let r = s.range(of: #"av[0-9]{5,}"#, options: [.regularExpression, .caseInsensitive]) {
      return String(s[r]).lowercased()
    }
    return nil
  }

  static func resolve(from text: String,
                      completion: @escaping (Swift.Result<MediaBundle, Error>) -> Void) {
    guard let url = ShareTextParser.extractURL(from: text) else {
      completion(.failure(ResolveError.noLink))
      return
    }

    // 已经是 bilibili.com/video/BV... 就直接用
    if let id = videoID(from: url), url.host?.contains("bilibili") == true {
      fetchPlayInfo(id: id, pageURL: url, completion: completion)
      return
    }

    // b23.tv 短链先展开
    expand(url) { final in
      guard let final else {
        completion(.failure(ResolveError.failed("短链展开失败。")))
        return
      }
      if let id = videoID(from: final) {
        fetchPlayInfo(id: id, pageURL: final, completion: completion)
      } else {
        // 展开后还是没有 ID：直接扒页面
        scrapePage(final, completion: completion)
      }
    }
  }

  // MARK: playurl 接口

  private static func fetchPlayInfo(_ id: String,
                                    pageURL: URL,
                                    completion: @escaping (Swift.Result<MediaBundle, Error>) -> Void) {
    let param = id.hasPrefix("av") ? "avid=\(id.dropFirst(2))" : "bvid=\(id)"
    let api = "https://api.bilibili.com/x/player/playurl?\(param)&qn=80&fnval=16&fourk=1"
    guard let apiURL = URL(string: api) else {
      completion(.failure(ResolveError.failed("接口地址构造失败。")))
      return
    }

    var req = URLRequest(url: apiURL, timeoutInterval: 15)
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: req) { data, _, err in
      guard let data,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        DispatchQueue.main.async {
          completion(.failure(ResolveError.failed(
            err?.localizedDescription ?? "接口无响应。")))
        }
        return
      }

      DispatchQueue.main.async {
        guard let code = root["code"] as? Int, code == 0,
              let info = root["data"] as? [String: Any] else {
          // 接口拿不到（常见于需要登录），退回去扒页面
          scrapePage(pageURL, completion: completion)
          return
        }

        var videos: [URL] = []

        // dash 格式：音视频分离
        if let dash = info["dash"] as? [String: Any] {
          if let vlist = dash["video"] as? [[String: Any]] {
            // 按带宽从高到低排，取前几个
            let sorted = vlist.sorted {
              ($0["bandwidth"] as? Int ?? 0) > ($1["bandwidth"] as? Int ?? 0)
            }
            for v in sorted.prefix(3) {
              if let base = v["baseUrl"] as? String ?? v["base_url"] as? String,
                 let u = URL(string: base) {
                videos.append(u)
              }
            }
          }
          // 音频单独一条，一并给出来
          if let alist = dash["audio"] as? [[String: Any]],
             let a = alist.first,
             let base = a["baseUrl"] as? String ?? a["base_url"] as? String,
             let u = URL(string: base) {
            videos.append(u)
          }
        }

        // durl 格式：整段 mp4
        if videos.isEmpty, let durl = info["durl"] as? [[String: Any]] {
          for d in durl.prefix(3) {
            if let u = d["url"] as? String, let url = URL(string: u) {
              videos.append(url)
            }
          }
        }

        let title = (info["title"] as? String)
          ?? ((info["share_subtitle"] as? String))
          ?? "B 站视频"

        if videos.isEmpty {
          scrapePage(pageURL, completion: completion)
        } else {
          completion(.success(MediaBundle(title: title, author: "",
                                          videos: videos, images: [],
                                          siteName: "哔哩哔哩")))
        }
      }
    }.resume()
  }

  // MARK: 页面兜底

  private static func scrapePage(_ url: URL,
                                 completion: @escaping (Swift.Result<MediaBundle, Error>) -> Void) {
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: req) { data, _, err in
      guard let data, let html = String(data: data, encoding: .utf8) else {
        DispatchQueue.main.async {
          completion(.failure(ResolveError.failed(
            err?.localizedDescription ?? "页面读取失败。")))
        }
        return
      }

      var videos: [URL] = []
      var title = "B 站视频"

      // 页面里内嵌的 playinfo
      let patterns = [
        #""baseUrl":"([^"]+)""#,
        #""base_url":"([^"]+)""#,
        #""url":"(https:[^"]+\.(?:mp4|m4s)[^"]*)""#,
      ]
      for p in patterns {
        if let re = try? NSRegularExpression(pattern: p) {
          let ns = html as NSString
          let ms = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
          for m in ms.prefix(12) {
            if m.numberOfRanges > 1 {
              var s = ns.substring(with: m.range(at: 1))
              s = s.replacingOccurrences(of: "\\/", with: "/")
              s = s.replacingOccurrences(of: "\\u002F", with: "/")
              if let u = URL(string: s), !videos.contains(u) {
                videos.append(u)
              }
            }
          }
        }
        if !videos.isEmpty { break }
      }

      // og:title
      if let r = html.range(of: #"<meta[^>]+property="og:title"[^>]+content="([^"]+)""#,
                            options: .regularExpression) {
        let seg = String(html[r])
        if let cr = seg.range(of: #"content="([^"]+)""#, options: .regularExpression) {
          title = String(seg[cr])
            .replacingOccurrences(of: "content=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        }
      }

      DispatchQueue.main.async {
        if videos.isEmpty {
          completion(.failure(ResolveError.failed(
            "没解析到 B 站直链。可能是充电专属、番剧或需要登录的视频。")))
        } else {
          completion(.success(MediaBundle(title: title, author: "",
                                          videos: videos, images: [],
                                          siteName: "哔哩哔哩")))
        }
      }
    }.resume()
  }
}
