import Foundation
import Combine

/// 引擎的固定参数。
///
/// 放在类型外面是有意的：`DownloadEngine` 是 MainActor 隔离的，它自己的静态常量
/// 也带隔离，出现在默认参数里会报警告（Swift 6 里是错误）。这里都是纯常量，
/// 不需要任何隔离。
enum EngineLimits {
  /// 用户设定的并发上限。真正并发还要和站点推荐值取小。
  static let maxThreads = 32
  /// 单段最小字节数：切太细会让请求开销盖过收益。
  static let minSegmentBytes: Int64 = 2 * 1024 * 1024
  /// 探测超时。
  static let probeTimeout: TimeInterval = 20
  /// 单段最多重试次数。
  static let maxSegmentRetries = 4
  /// 临时文件往目标文件搬的时候每次读写多少。
  static let copyChunk = 512 * 1024
}

/// 下载引擎：多线程分块 + 断点续传 + 网盘头补全。
///
/// 设计参照 thunder-lite 的 downloader.js：
///   - 探测用 `GET` + `Range: bytes=0-0`，不用 HEAD —— 阿里云盘 OSS、夸克这类
///     CDN 会拒绝 HEAD，只有 GET 才返回真实大小。
///   - 文件切成若干段并行拉，每段独立 Range 请求，失败单独重试。
///   - 进度写进 App 支持目录的 tasks.json，重开 App 能接着下。
///   - 并发数按站点上限收窄：夸克/UC 能拉满 32，百度 8、阿里 4，
///     超过就被 CDN 限速甚至 412 风控。
///
/// 两个容易踩的坑，代码里都处理了：
///   1. `URLSession.shared` 每个 host 只开 6 条连接，32 线程会被它卡成 6；
///      所以这里用自己配的 session，把 httpMaximumConnectionsPerHost 提到 32。
///   2. 逐字节 `for try await byte in bytes` 每个字节一次挂起，实测不到 1MB/s；
///      改成每段走 `download(for:)` 落到临时文件，再按 512KB 拷进目标文件。
@MainActor
final class DownloadEngine: ObservableObject {
  static let shared = DownloadEngine()

  @Published private(set) var tasks: [DownloadTask] = []

  /// 有任务正在跑（用来决定要不要保持屏幕常亮）。
  var hasActiveTask: Bool {
    tasks.contains { $0.state == .downloading || $0.state == .waiting || $0.state == .probing }
  }

  private var running: [UUID: Task<Void, Never>] = [:]

  /// 正在跑的 WKDownload 兜底下载器。任务结束前必须保住引用。
  var webkitDownloaders: [UUID: WebKitDownloader] = [:]

  /// 惰性创建：TaskStore 是 MainActor 隔离的，不能出现在默认参数里。
  private lazy var store = TaskStore()

  /// 专用会话。默认 session 每条 host 仅 6 连接，不开这个 32 线程没意义。
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = EngineLimits.maxThreads
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60 * 60 * 12
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.urlCache = nil
    config.httpShouldUsePipelining = false
    // 别让 URLSession 自己加 Cookie：有些 CDN 看到系统 Cookie 反而拦。
    // 需要的 Cookie 由 MediaRequestHeaders 显式放进去。
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.httpCookieStorage = nil
    // 显式声明可接受的编码，避免某些 CDN 见到默认的 gzip 就返回 403。
    config.httpAdditionalHeaders = [
      "Accept-Encoding": "identity",
    ]
    return URLSession(configuration: config)
  }()

  init() {}

  // MARK: - 任务生命周期

  /// 新建一个任务并立刻开跑。返回的任务对象由 `tasks` 持有。
  ///
  /// - Parameter cookie: 该网盘用户填的 Cookie；按站点的 sendCookie 决定要不要带。
  /// - Parameter forceCookie: 对默认不带的站点（夸克/UC）强制带上 Cookie。
  @discardableResult
  func add(url: String, saveTo directory: URL, threads: Int = EngineLimits.maxThreads,
           cookie: String? = nil, forceCookie: Bool = false,
           extraHeaders: [String: String] = [:]) throws -> DownloadTask {
    guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme)
    else {
      throw EngineError.badURL
    }
    if let share = NetdiskSupport.sharePageName(parsed.absoluteString) {
      throw EngineError.sharePage(share)
    }

    let resolved = NetdiskSupport.resolve(url: parsed.absoluteString,
                                         extra: extraHeaders, cookie: cookie,
                                         forceCookie: forceCookie)
    guard let target = URL(string: resolved.url) else { throw EngineError.badURL }

    // 补默认请求头。
    //
    // URLSession 默认 UA 是 "ThunderLite/1 CFNetwork/... iOS 17.0"，
    // 图片 CDN、视频 CDN 看到这个会直接 403 —— 它们在预览里能放（AVPlayer 走的是
    // 系统播放器的 UA），但用引擎下就失败。这里统一补成 Safari 的 UA。
    //
    // Referer 也补一个：不少 CDN 校验来源站，没有就拒绝。
    var headers = resolved.headers
    if headers["User-Agent"] == nil, headers["user-agent"] == nil {
      headers["User-Agent"] = Self.defaultUserAgent
    }
    if headers["Referer"] == nil, headers["referer"] == nil {
      headers["Referer"] = Self.defaultReferer(for: target)
    }
    if headers["Accept"] == nil {
      headers["Accept"] = "*/*"
    }
    if headers["Accept-Language"] == nil {
      headers["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8"
    }

    let task = DownloadTask(url: target, saveDir: directory,
                            requestedThreads: threads, headers: headers,
                            site: resolved.site)
    tasks.insert(task, at: 0)
    start(task)
    return task
  }

  /// 通用 Safari UA。别改成 App 自己的标识，很多 CDN 会拦。
  static let defaultUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  /// 按目标域名猜一个 Referer。猜到就用域名本身，猜不到用它的根域。
  static func defaultReferer(for url: URL) -> String {
    guard let host = url.host?.lowercased() else { return "" }
    // 已知站点用官网做 Referer（CDN 白名单里通常就是这些）
    if host.contains("bilibili") || host.contains("hdslb")
        || host.contains("bilivideo") {
      return "https://www.bilibili.com/"
    }
    if host.contains("douyin") || host.contains("douyinvod")
        || host.contains("byteimg") || host.contains("bytedance")
        || host.contains("zjcdn") || host.contains("snssdk") {
      return "https://www.douyin.com/"
    }
    if host.contains("weibo") || host.contains("sinaimg")
        || host.contains("weibocdn") {
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
    if host.contains("qq.com") || host.contains("gtimg") {
      return "https://www.qq.com/"
    }
    // 通用兜底：https://<根域>/
    let parts = host.split(separator: ".")
    if parts.count >= 2 {
      let root = parts.suffix(2).joined(separator: ".")
      return "https://\(root)/"
    }
    return "https://\(host)/"
  }

  func start(_ task: DownloadTask) {
    guard running[task.id] == nil else { return }
    task.state = .probing
    running[task.id] = Task { [weak self] in
      await self?.run(task)
      await MainActor.run { _ = self?.running.removeValue(forKey: task.id) }
    }
  }

  func pause(_ task: DownloadTask) {
    task.state = .paused
    task.resetSpeed()
    running.removeValue(forKey: task.id)?.cancel()
  }

  func resume(_ task: DownloadTask) {
    guard task.state == .paused || task.state == .failed else { return }
    start(task)
  }

  func remove(_ task: DownloadTask, deleteFile: Bool) {
    running.removeValue(forKey: task.id)?.cancel()
    tasks.removeAll { $0.id == task.id }
    store.forget(task)
    if deleteFile {
      try? FileManager.default.removeItem(at: task.fileURL)
      try? FileManager.default.removeItem(at: task.stateURL)
    }
  }

  // MARK: - 主流程

  private func run(_ task: DownloadTask) async {
    do {
      try await probe(task)
      guard task.state != .paused else { return }
      try await download(task)
      guard task.state != .paused else { return }
      task.state = .done
      task.finishedAt = Date()
      task.resetSpeed()
      try? FileManager.default.removeItem(at: task.stateURL)
      store.save(task)
    } catch is CancellationError {
      task.state = .paused
      task.resetSpeed()
      store.save(task)
    } catch {
      // 401/403 走 WKDownload：用它自己的网络栈带齐 Cookie/UA/Referer 再下一次。
      // 这类 CDN 的签名直链用 URLSession 怎么补头都可能被拒，换会话最直接。
      if case EngineError.http(let code, _) = error,
         (code == 401 || code == 403),
         !task.usedWebKitFallback {
        task.usedWebKitFallback = true
        task.state = .downloading
        task.errorText = nil
        store.save(task)

        let ok = await downloadViaWebKit(task)
        if ok {
          task.state = .done
          task.finishedAt = Date()
          task.resetSpeed()
          try? FileManager.default.removeItem(at: task.stateURL)
          store.save(task)
          return
        }

        // WKDownload 也被拒：说明直链确实过期了，去来源页抓一条新的再试。
        if !task.retriedFreshLink,
           let origin = task.headers["Referer"] ?? task.headers["referer"],
           let pageURL = URL(string: origin) {
          task.retriedFreshLink = true
          task.state = .waiting
          task.errorText = "CDN 拒绝了直链，正在去原页面重新抓取…"
          store.save(task)

          let fresh = await LinkRefresherBridge.shared.refresh(
            pageURL: pageURL,
            preferHost: task.url.host)

          if let fresh {
            task.switchURL(fresh)
            // 换链后重跑一次（两个标志位都已置位，不会循环）
            await run(task)
            return
          }
        }
      }

      task.state = .failed
      task.resetSpeed()
      task.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      store.save(task)
    }
  }

  /// 用 WKDownload 兜底下载。成功返回 true。
  private func downloadViaWebKit(_ task: DownloadTask) async -> Bool {
    // 文件名还没定就先猜一个
    if task.fileName.isEmpty {
      let last = task.url.lastPathComponent
      task.fileName = last.isEmpty
        ? "media-\(Int(Date().timeIntervalSince1970)).mp4"
        : Self.sanitize(last)
    }

    let dest = task.fileURL
    let referer = task.headers["Referer"] ?? task.headers["referer"]
    let ua = task.headers["User-Agent"] ?? task.headers["user-agent"]

    task.totalBytes = 0
    task.receivedBytes = 0
    task.resetSpeed()

    let engine = self

    return await withCheckedContinuation { cont in
      let dl = WebKitDownloader()
      engine.webkitDownloaders[task.id] = dl

      dl.download(url: task.url,
                  to: dest,
                  referer: referer,
                  userAgent: ua,
                  timeout: 300) { done, total in
        task.receivedBytes = done
        if total > 0 { task.totalBytes = total }
        task.recordProgress()
      } completion: { outcome in
        engine.webkitDownloaders.removeValue(forKey: task.id)
        switch outcome {
        case .success(let fileURL):
          let size = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
          task.receivedBytes = size
          task.totalBytes = size
          cont.resume(returning: true)
        case .failure(let err):
          task.errorText = err.localizedDescription
          cont.resume(returning: false)
        }
      }
    }
  }

  // MARK: - 探测

  private func probe(_ task: DownloadTask) async throws {
    task.state = .probing
    var request = URLRequest(url: task.url, timeoutInterval: EngineLimits.probeTimeout)
    request.httpMethod = "GET"
    for (k, v) in task.headers { request.setValue(v, forHTTPHeaderField: k) }
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

    // 外层再兜一个硬超时：有些 CDN 收到 Range 后既不回 206 也不结束连接，
    // session.bytes(for:) 会一直挂着，任务就卡在「准备中 / 排队中 0 B」。
    let (bytes, response) = try await withThrowingTaskGroup(
      of: (URLSession.AsyncBytes, URLResponse).self
    ) { group in
      group.addTask {
        try await self.session.bytes(for: request)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(EngineLimits.probeTimeout * 1_000_000_000))
        throw EngineError.http(-1, "探测超时（服务器没有在 \(Int(EngineLimits.probeTimeout)) 秒内响应）。")
      }
      guard let first = try await group.next() else {
        throw EngineError.badResponse
      }
      group.cancelAll()
      return first
    }
    guard let http = response as? HTTPURLResponse else {
      bytes.task.cancel()
      throw EngineError.badResponse
    }
    bytes.task.cancel()

    let status = http.statusCode
    guard status == 206 || status == 200 else {
      throw EngineError.http(status, NetdiskSupport.hint(for: status))
    }

    var total: Int64 = 0
    var supportsRange = false
    if status == 206 {
      // Content-Range: bytes 0-0/12345
      if let cr = http.value(forHTTPHeaderField: "Content-Range"),
         let slash = cr.split(separator: "/").last, let n = Int64(slash) {
        total = n
      }
      supportsRange = true
    } else {
      total = http.expectedContentLength > 0 ? http.expectedContentLength : 0
      let accept = http.value(forHTTPHeaderField: "Accept-Ranges") ?? ""
      supportsRange = accept.lowercased().contains("bytes")
    }

    guard total > 0 else { throw EngineError.unknownSize }

    // 网盘把「要登录」返回成一个小网页（200 + text/html），不拦住会当成文件下下来。
    let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    if contentType.lowercased().contains("text/html") && total < 2 * 1024 * 1024 {
      throw EngineError.htmlInsteadOfFile
    }

    task.totalBytes = total
    task.resumable = supportsRange
    if task.fileName.isEmpty {
      task.fileName = Self.fileName(from: http, url: task.url)
    }
    try Self.ensureFile(task.fileURL, size: total)
    task.state = .waiting
    store.save(task)
  }

  // MARK: - 分块下载

  private func download(_ task: DownloadTask) async throws {
    task.state = .downloading
    let total = task.totalBytes

    // 不支持 Range 的服务器只能单流顺序下。
    guard task.resumable else {
      try await downloadSingleStream(task)
      return
    }

    let segments = Self.planSegments(total: total, threads: effectiveThreads(task))
    task.segments = segments
    task.receivedBytes = segments.reduce(0) { $0 + $1.received }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in segments.indices {
        group.addTask { [weak self] in
          guard let self else { return }
          try await self.fetchSegment(task, index: index)
        }
      }
      try await group.waitForAll()
    }

    // 有些服务器即使声明支持 Range，某些段仍会短少；补齐后校验。
    task.receivedBytes = task.segments.reduce(0) { $0 + $1.received }
    guard task.receivedBytes >= total else { throw EngineError.incomplete }
  }

  /// 不分块的退路：一条流从头拉到尾。
  private func downloadSingleStream(_ task: DownloadTask) async throws {
    var request = URLRequest(url: task.url, timeoutInterval: 60)
    for (k, v) in task.headers { request.setValue(v, forHTTPHeaderField: k) }

    let (tempURL, response) = try await session.download(for: request)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    guard let http = response as? HTTPURLResponse,
          http.statusCode == 200 || http.statusCode == 206 else {
      throw EngineError.badResponse
    }

    let out = try FileHandle(forWritingTo: task.fileURL)
    defer { try? out.close() }
    try out.truncate(atOffset: 0)

    let input = try FileHandle(forReadingFrom: tempURL)
    defer { try? input.close() }

    while true {
      if task.state == .paused || Task.isCancelled { throw CancellationError() }
      guard let chunk = try input.read(upToCount: EngineLimits.copyChunk), !chunk.isEmpty else { break }
      try out.write(contentsOf: chunk)
      task.receivedBytes += Int64(chunk.count)
      task.recordProgress()
    }
  }

  /// 拉一个分块，自带重试与续点。
  ///
  /// 整段交给 `download(for:)` 落到系统临时文件，再按块搬进目标文件的对应偏移。
  /// 这样既不占内存（峰值一个块），也不会因为逐字节 await 把速度拖死。
  private func fetchSegment(_ task: DownloadTask, index: Int) async throws {
    var attempt = 0
    while attempt <= EngineLimits.maxSegmentRetries {
      if task.state == .paused || Task.isCancelled { throw CancellationError() }
      let seg = task.segments[index]
      let from = seg.start + seg.received
      guard from <= seg.end else { return }

      var request = URLRequest(url: task.url, timeoutInterval: 60)
      for (k, v) in task.headers { request.setValue(v, forHTTPHeaderField: k) }
      request.setValue("bytes=\(from)-\(seg.end)", forHTTPHeaderField: "Range")

      do {
        let (tempURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse else { throw EngineError.badResponse }
        guard http.statusCode == 206 || http.statusCode == 200 else {
          throw EngineError.http(http.statusCode, NetdiskSupport.hint(for: http.statusCode))
        }
        try merge(tempURL, into: task, index: index, at: from)
        store.save(task)
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempt += 1
        if attempt > EngineLimits.maxSegmentRetries { throw error }
        // 退避重试：CDN 抖动或短时限流
        let delay = UInt64(pow(1.8, Double(attempt)) * 400_000_000)
        try await Task.sleep(nanoseconds: delay)
      }
    }
  }

  /// 把临时文件的内容写到目标文件的指定偏移。
  ///
  /// 全程同步、中间没有 await，所以 32 个分块即便并发也不会互相插队改写偏移。
  private func merge(_ tempURL: URL, into task: DownloadTask, index: Int, at offset: Int64) throws {
    let out = try FileHandle(forWritingTo: task.fileURL)
    defer { try? out.close() }
    let input = try FileHandle(forReadingFrom: tempURL)
    defer { try? input.close() }

    try out.seek(toOffset: UInt64(offset))
    while true {
      if task.state == .paused || Task.isCancelled { throw CancellationError() }
      guard let chunk = try input.read(upToCount: EngineLimits.copyChunk), !chunk.isEmpty else { break }
      try out.write(contentsOf: chunk)
      let delta = Int64(chunk.count)
      task.segments[index].received += delta
      task.receivedBytes += delta
      task.recordProgress()
    }
  }

  // MARK: - 工具

  /// 用户设定值与站点推荐值取小；站点未知时不额外限制。
  private func effectiveThreads(_ task: DownloadTask) -> Int {
    let wanted = min(max(1, task.requestedThreads), EngineLimits.maxThreads)
    if let cap = task.site?.maxThreads { return min(wanted, cap) }
    return wanted
  }

  /// 把文件切成等长的 N 段。
  static func planSegments(total: Int64, threads: Int) -> [Segment] {
    let maxBySize = max(1, Int(total / EngineLimits.minSegmentBytes))
    let count = max(1, min(threads, maxBySize))
    let size = total / Int64(count)
    var out: [Segment] = []
    out.reserveCapacity(count)
    for i in 0..<count {
      let start = Int64(i) * size
      let end = (i == count - 1) ? total - 1 : start + size - 1
      out.append(Segment(index: i, start: start, end: end))
    }
    return out
  }

  /// 预分配文件，避免多线程写同一文件时反复扩容。
  static func ensureFile(_ url: URL, size: Int64) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let current = try handle.seekToEnd()
    if current < UInt64(size) {
      try handle.truncate(atOffset: UInt64(size))
    }
  }

  static func fileName(from response: HTTPURLResponse, url: URL) -> String {
    if let cd = response.value(forHTTPHeaderField: "Content-Disposition"),
       let name = parseDisposition(cd), !name.isEmpty {
      return sanitize(name)
    }
    let last = url.lastPathComponent
    if !last.isEmpty, last != "/" { return sanitize(last) }
    return "download-\(Int(Date().timeIntervalSince1970))"
  }

  /// `attachment; filename*=UTF-8''a.zip` 与 `filename="a.zip"` 两种写法。
  static func parseDisposition(_ value: String) -> String? {
    if let r = value.range(of: "filename*=", options: .caseInsensitive) {
      var rest = String(value[r.upperBound...])
      if let semi = rest.firstIndex(of: ";") { rest = String(rest[..<semi]) }
      rest = rest.trimmingCharacters(in: .whitespaces)
      if let quote = rest.firstIndex(of: "'") {
        let after = rest[rest.index(quote, offsetBy: 1)...]
        if let second = after.firstIndex(of: "'") {
          let encoded = String(after[after.index(after: second)...])
          if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
            return decoded
          }
        }
      }
    }
    if let r = value.range(of: "filename=", options: .caseInsensitive) {
      var rest = String(value[r.upperBound...])
      if let semi = rest.firstIndex(of: ";") { rest = String(rest[..<semi]) }
      rest = rest.trimmingCharacters(in: .whitespaces)
      rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !rest.isEmpty { return rest }
    }
    return nil
  }

  /// 去掉路径分隔符与控制字符，避免写到目录外面。
  static func sanitize(_ name: String) -> String {
    let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    let cleaned = name.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) }
    let text = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = 180
    return text.count > limit ? String(text.prefix(limit)) : (text.isEmpty ? "download" : text)
  }
}

// MARK: - 数据模型

struct Segment: Codable, Identifiable {
  var id: Int { index }
  let index: Int
  let start: Int64
  let end: Int64
  var received: Int64 = 0

  var length: Int64 { end - start + 1 }
  var isDone: Bool { received >= length }
}

enum DownloadState: String, Codable {
  case probing, waiting, downloading, paused, done, failed
}

@MainActor
final class DownloadTask: ObservableObject, Identifiable {
  let id = UUID()
  /// 媒体直链。直链签名过期时会被 switchURL 换成新抓到的。
  @Published private(set) var url: URL
  let saveDir: URL
  let requestedThreads: Int
  /// 请求头。切链接时一起更新（Referer/Cookie 可能也要换）。
  @Published private(set) var headers: [String: String]
  let site: NetdiskSite?
  let createdAt = Date()

  /// 已经因为 403 重抓过一次直链。防止无限重试。
  var retriedFreshLink = false

  /// 已经用过 WKDownload 兜底。只兜一次。
  var usedWebKitFallback = false

  @Published var state: DownloadState = .waiting
  @Published var fileName: String = ""
  @Published var totalBytes: Int64 = 0
  @Published var receivedBytes: Int64 = 0
  @Published var segments: [Segment] = []
  @Published var resumable = false
  @Published var errorText: String?
  @Published var updatedAt = Date()
  @Published var finishedAt: Date?

  /// 实时速度（字节/秒）。由引擎在写数据时喂样本，界面直接读。
  @Published private(set) var bytesPerSecond: Double = 0

  /// 本次任务出现过的峰值速度，结算时一起显示。
  @Published private(set) var peakBytesPerSecond: Double = 0

  /// 滑动窗口里的采样点：(时间, 累计字节)。
  private var samples: [(t: TimeInterval, bytes: Int64)] = []
  /// 窗口长度。1.5 秒既够平滑，又能及时反映掉速。
  private static let window: TimeInterval = 1.5

  /// 最后一次真正收到数据的时刻。用于判断「是不是卡住了」。
  ///
  /// 没有这个字段的话，速度只会在写数据时重算；一旦停滞（CDN 限流、
  /// 分段重连、退避等待），`bytesPerSecond` 会永远停在最后一个值，
  /// 界面上就是一个不动的假数字。
  private var lastDataAt: TimeInterval = 0
  /// 超过这个时长没有新数据，就认为速度归零。
  private static let stallAfter: TimeInterval = 1.5

  init(url: URL, saveDir: URL, requestedThreads: Int,
       headers: [String: String], site: NetdiskSite?) {
    self.url = url
    self.saveDir = saveDir
    self.requestedThreads = requestedThreads
    self.headers = headers
    self.site = site
  }

  /// 直链过期时换成新地址，并重置进度（新链接的分段要重新规划）。
  func switchURL(_ fresh: URL) {
    guard fresh != url else { return }
    url = fresh
    // Referer/Cookie 保留，UA 保留；只换地址
    // 进度和分段全部清掉：新链接的 Range 语义未必一致，不能沿用旧偏移
    segments = []
    receivedBytes = 0
    totalBytes = 0
    resumable = false
    errorText = nil
    resetSpeed()
    // 旧的目标文件也删掉，避免把新数据写到旧文件的错误偏移上
    try? FileManager.default.removeItem(at: fileURL)
  }

  var fileURL: URL { saveDir.appendingPathComponent(fileName.isEmpty ? "download" : fileName) }
  var stateURL: URL { saveDir.appendingPathComponent(".thunderlite-\(id.uuidString).json") }

  var progress: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }

  // MARK: - 测速

  /// 记一个采样点并重算速度。引擎每写一批数据调一次。
  func recordProgress(now: TimeInterval = Date().timeIntervalSince1970) {
    lastDataAt = now
    samples.append((t: now, bytes: receivedBytes))
    // 只留窗口内的样本，但至少留两个点，否则算不出差值。
    while samples.count > 2, now - samples[0].t > Self.window {
      samples.removeFirst()
    }
    guard let first = samples.first, let last = samples.last else {
      bytesPerSecond = 0
      return
    }
    let dt = last.t - first.t
    // 之前是 0.05：速度很快时两个样本间隔可能不到 50ms，于是直接 return，
    // 速度就停在旧值上不动。改成两个样本都等于同一时刻才跳过。
    guard dt > 0.001 else { return }
    let delta = Double(last.bytes - first.bytes)
    bytesPerSecond = max(0, delta / dt)
    if bytesPerSecond > peakBytesPerSecond { peakBytesPerSecond = bytesPerSecond }
    updatedAt = Date()
  }

  /// 每秒由界面调用一次：长时间没收到数据就把速度清零。
  ///
  /// 下载停滞时没有任何回调，必须靠外部心跳才能把「假的固定速度」清掉。
  func tickSpeed(now: TimeInterval = Date().timeIntervalSince1970) {
    guard state == .downloading else { return }
    if lastDataAt > 0, now - lastDataAt > Self.stallAfter {
      samples.removeAll()
      bytesPerSecond = 0
    }
  }

  /// 停下时把速度归零，免得暂停后还挂着旧数字。
  func resetSpeed() {
    samples.removeAll()
    bytesPerSecond = 0
    lastDataAt = 0
  }

  /// 界面用的一行速度文本；没有速度时返回 nil，方便调用方决定要不要占位。
  var speedLabel: String? {
    guard state == .downloading, bytesPerSecond > 0 else { return nil }
    return ByteText.perSecond(bytesPerSecond)
  }

  /// 速度数字（不含单位），给大号显示用。
  var speedValue: String {
    ByteText.valueOnly(bytesPerSecond)
  }

  /// 速度单位，给大号显示用。
  var speedUnit: String {
    ByteText.unitOnly(bytesPerSecond)
  }

  /// 完成后的平均速度，作为结算信息。
  var speedText: String {
    guard let finishedAt else { return "" }
    let elapsed = finishedAt.timeIntervalSince(createdAt)
    guard elapsed > 0 else { return "" }
    return ByteText.perSecond(Double(totalBytes) / elapsed)
  }

  /// 剩余时间估算。样本太少或速度太低时返回 nil。
  var remainingLabel: String? {
    guard state == .downloading, bytesPerSecond > 1, totalBytes > receivedBytes else { return nil }
    let seconds = Double(totalBytes - receivedBytes) / bytesPerSecond
    guard seconds.isFinite, seconds > 0 else { return nil }
    if seconds < 60 { return "约 \(Int(seconds.rounded())) 秒" }
    if seconds < 3600 { return "约 \(Int(seconds / 60)) 分钟" }
    return String(format: "约 %.1f 小时", seconds / 3600)
  }
}

// MARK: - 错误

enum EngineError: LocalizedError {
  case badURL
  case sharePage(String)
  case badResponse
  case unknownSize
  case htmlInsteadOfFile
  case incomplete
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .badURL:
      return "链接格式不对，需要 http:// 或 https:// 开头。"
    case .sharePage(let name):
      return "这是\(name)的分享页，不是直链。请先在网页里「下载」拿到直链。"
    case .badResponse:
      return "服务器没有正常响应。"
    case .unknownSize:
      return "服务器没返回文件大小，可能链接已过期或不是直链。"
    case .htmlInsteadOfFile:
      return "服务器返回的是网页而不是文件：直链多半已过期，或需要补充 Cookie。"
    case .incomplete:
      return "部分分块没有下完，可以点继续重试。"
    case .http(let code, let hint):
      return "HTTP \(code)：\(hint)"
    }
  }
}

// MARK: - 版本存储

/// 任务状态的持久化。存成 JSON 放在 App 支持目录，重开能恢复列表。
@MainActor
final class TaskStore {
  private let fileURL: URL

  init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ThunderLite", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    fileURL = base.appendingPathComponent("tasks.json")
  }

  func save(_ task: DownloadTask) {
    var all = loadRaw()
    let record = Record(task)
    if let i = all.firstIndex(where: { $0.id == record.id }) { all[i] = record }
    else { all.append(record) }
    write(all)
  }

  func forget(_ task: DownloadTask) {
    var all = loadRaw()
    all.removeAll { $0.id == task.id.uuidString }
    write(all)
  }

  func restore() -> [Record] { loadRaw() }

  private func loadRaw() -> [Record] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
  }

  private func write(_ records: [Record]) {
    guard let data = try? JSONEncoder().encode(records) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  struct Record: Codable {
    let id: String
    let url: String
    let saveDir: String
    let fileName: String
    let state: String
    let totalBytes: Int64
    let receivedBytes: Int64
    let threads: Int

    @MainActor
    init(_ t: DownloadTask) {
      id = t.id.uuidString
      url = t.url.absoluteString
      saveDir = t.saveDir.path
      fileName = t.fileName
      state = t.state.rawValue
      totalBytes = t.totalBytes
      receivedBytes = t.receivedBytes
      threads = t.requestedThreads
    }
  }
}

// MARK: - 格式化

enum ByteText {
  static func bytes(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(n)
    var i = 0
    while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
  }

  static func perSecond(_ n: Double) -> String {
    bytes(Int64(n)) + "/s"
  }

  /// 只给数字部分：`12.3`。
  static func valueOnly(_ n: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = max(0, n)
    var i = 0
    while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f" : "%.1f", value)
  }

  /// 只给单位部分：`MB/s`。
  static func unitOnly(_ n: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = max(0, n)
    var i = 0
    while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
    return units[i] + "/s"
  }
}
