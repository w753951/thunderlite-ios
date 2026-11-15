import Foundation

/// 下载引擎：多线程分块 + 断点续传 + 网盘头补全。
///
/// 设计参照 thunder-lite 的 downloader.js：
///   - 探测用 `GET` + `Range: bytes=0-0`，不用 HEAD —— 阿里云盘 OSS、夸克这类
///     CDN 会拒绝 HEAD，只有 GET 才返回真实大小。
///   - 文件切成若干段并行拉，每段独立 Range 请求，失败单独重试。
///   - 进度写进同名 `.thunderlite.json` 旁文件，重开 App 能接着下。
///   - 并发数按站点上限收窄：夸克/UC 能拉满 32，百度 8、阿里 4，
///     超过就被 CDN 限速甚至 412 风控。
@MainActor
final class DownloadEngine: ObservableObject {
  static let shared = DownloadEngine()

  /// 用户设定的并发上限。真正并发还要和站点推荐值取小。
  static let maxThreads = 32
  /// 单段最小字节数：切太细会让请求开销盖过收益。
  static let minSegmentBytes: Int64 = 2 * 1024 * 1024
  /// 探测超时。
  static let probeTimeout: TimeInterval = 20
  /// 单段最多重试次数。
  static let maxSegmentRetries = 4

  @Published private(set) var tasks: [DownloadTask] = []

  /// 有任务正在跑（用来决定要不要保持屏幕常亮）。
  var hasActiveTask: Bool {
    tasks.contains { $0.state == .downloading || $0.state == .waiting || $0.state == .probing }
  }

  private var running: [UUID: Task<Void, Never>] = [:]
  private let store: TaskStore

  init(store: TaskStore = TaskStore()) {
    self.store = store
  }

  // MARK: - 任务生命周期

  /// 新建一个任务并立刻开跑。返回的任务对象由 `tasks` 持有。
  @discardableResult
  func add(url: String, saveTo directory: URL, threads: Int = maxThreads,
           extraHeaders: [String: String] = [:]) throws -> DownloadTask {
    guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme)
    else {
      throw EngineError.badURL
    }
    if let share = NetdiskSupport.sharePageName(parsed.absoluteString) {
      throw EngineError.sharePage(share)
    }

    let resolved = NetdiskSupport.resolve(url: parsed.absoluteString, extra: extraHeaders)
    let task = DownloadTask(url: resolved.url, saveDir: directory,
                            requestedThreads: threads, headers: resolved.headers,
                            site: resolved.site)
    tasks.insert(task, at: 0)
    start(task)
    return task
  }

  func start(_ task: DownloadTask) {
    guard running[task.id] == nil else { return }
    task.state = .probing
    running[task.id] = Task { [weak self] in
      await self?.run(task)
      await MainActor.run { self?.running.removeValue(forKey: task.id) }
    }
  }

  func pause(_ task: DownloadTask) {
    task.state = .paused
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
      try? FileManager.default.removeItem(at: task.stateURL)
      store.save(task)
    } catch is CancellationError {
      task.state = .paused
      store.save(task)
    } catch {
      task.state = .failed
      task.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      store.save(task)
    }
  }

  // MARK: - 探测

  private func probe(_ task: DownloadTask) async throws {
    task.state = .probing
    var request = URLRequest(url: task.url, timeoutInterval: Self.probeTimeout)
    request.httpMethod = "GET"
    for (k, v) in task.headers { request.setValue(v, forHTTPHeaderField: k) }
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw EngineError.badResponse }
    // 只取头部，正文立刻丢掉。
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

    let handle = try FileHandle(forWritingTo: task.fileURL)
    defer { try? handle.close() }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in segments.indices {
        group.addTask { [weak self] in
          guard let self else { return }
          try await self.fetchSegment(task, index: index, handle: handle)
        }
      }
      try await group.waitForAll()
    }

    // 有些服务器即使声明支持 Range，某些段仍会短少；补齐后校验。
    task.receivedBytes = task.segments.reduce(0) { $0 + $1.received }
    guard task.receivedBytes >= total else { throw EngineError.incomplete }
    try handle.synchronize()
  }

  /// 不分块的退路：一条流从头拉到尾。
  private func downloadSingleStream(_ task: DownloadTask) async throws {
    var request = URLRequest(url: task.url)
    for (k, v) in task.headers { request.setValue(v, forHTTPHeaderField: k) }

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw EngineError.badResponse
    }
    let handle = try FileHandle(forWritingTo: task.fileURL)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)

    var buffer = Data()
    buffer.reserveCapacity(64 * 1024)
    var written: Int64 = 0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= 64 * 1024 {
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        task.receivedBytes = written
        Task { @MainActor in self.store.save(task) }
      }
      if task.state == .paused { throw CancellationError() }
    }
    if !buffer.isEmpty {
      try handle.write(contentsOf: buffer)
      written += Int64(buffer.count)
    }
    task.receivedBytes = written
  }

  /// 拉一个分块，自带重试与续点。
  private func fetchSegment(_ task: DownloadTask, index: Int, handle: FileHandle) async throws {
    var attempt = 0
    while attempt <= Self.maxSegmentRetries {
      if task.state == .paused || Task.isCancelled { throw CancellationError() }
      let seg = task.segments[index]
      let from = seg.start + seg.received
      guard from <= seg.end else { return }

      var request = URLRequest(url: task.url, timeoutInterval: 30)
      for (k, v) in task.headers { request.setValue(v, forHTTPHeaderField: k) }
      request.setValue("bytes=\(from)-\(seg.end)", forHTTPHeaderField: "Range")

      do {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.badResponse }
        guard http.statusCode == 206 else {
          throw EngineError.http(http.statusCode, NetdiskSupport.hint(for: http.statusCode))
        }

        var buffer = Data()
        buffer.reserveCapacity(128 * 1024)
        var offset = from
        for try await byte in bytes {
          if task.state == .paused || Task.isCancelled { throw CancellationError() }
          buffer.append(byte)
          if buffer.count >= 128 * 1024 {
            try Self.write(buffer, to: handle, at: offset)
            offset += Int64(buffer.count)
            let delta = Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            await MainActor.run {
              task.segments[index].received += delta
              task.receivedBytes += delta
              task.updatedAt = Date()
            }
          }
        }
        if !buffer.isEmpty {
          try Self.write(buffer, to: handle, at: offset)
          let delta = Int64(buffer.count)
          await MainActor.run {
            task.segments[index].received += delta
            task.receivedBytes += delta
          }
        }
        await MainActor.run { self.store.save(task) }
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        attempt += 1
        if attempt > Self.maxSegmentRetries { throw error }
        // 退避重试：CDN 抖动或短时限流
        let delay = UInt64(pow(1.8, Double(attempt)) * 400_000_000)
        try await Task.sleep(nanoseconds: delay)
      }
    }
  }

  // MARK: - 工具

  /// 用户设定值与站点推荐值取小；站点未知时不额外限制。
  private func effectiveThreads(_ task: DownloadTask) -> Int {
    let wanted = min(max(1, task.requestedThreads), Self.maxThreads)
    if let cap = task.site?.maxThreads { return min(wanted, cap) }
    return wanted
  }

  /// 把文件切成等长的 N 段。
  static func planSegments(total: Int64, threads: Int) -> [Segment] {
    let maxBySize = max(1, Int(total / minSegmentBytes))
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

  /// 定位写入。多线程各写各自的区段，不会互相覆盖。
  static func write(_ data: Data, to handle: FileHandle, at offset: Int64) throws {
    try handle.seek(toOffset: UInt64(offset))
    try handle.write(contentsOf: data)
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
  let url: URL
  let saveDir: URL
  let requestedThreads: Int
  let headers: [String: String]
  let site: NetdiskSite?
  let createdAt = Date()

  @Published var state: DownloadState = .waiting
  @Published var fileName: String = ""
  @Published var totalBytes: Int64 = 0
  @Published var receivedBytes: Int64 = 0
  @Published var segments: [Segment] = []
  @Published var resumable = false
  @Published var errorText: String?
  @Published var updatedAt = Date()
  @Published var finishedAt: Date?

  init(url: URL, saveDir: URL, requestedThreads: Int,
       headers: [String: String], site: NetdiskSite?) {
    self.url = url
    self.saveDir = saveDir
    self.requestedThreads = requestedThreads
    self.headers = headers
    self.site = site
  }

  var fileURL: URL { saveDir.appendingPathComponent(fileName.isEmpty ? "download" : fileName) }
  var stateURL: URL { saveDir.appendingPathComponent(".thunderlite-\(id.uuidString).json") }

  var progress: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }

  var speedText: String {
    guard let finishedAt else { return "" }
    let elapsed = finishedAt.timeIntervalSince(createdAt)
    guard elapsed > 0 else { return "" }
    return ByteText.perSecond(Double(totalBytes) / elapsed)
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
      return "这是\(name)的分享页，不是直链。请先在网页里「下载」拿到直链，或使用网盘转存工具。"
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
}
