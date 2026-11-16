import Foundation
import WebKit
import UIKit

// MARK: - 直链有效期

/// 从 URL 里读出土豪 CDN 的过期时间戳。
///
/// 抖音/西瓜/字节系在 URL 里塞 `deadline=`，其他 CDN 用 `expire=` / `e=` /
/// `expires=` / `x-expires=`。这些都是 Unix 秒。
/// 一旦过了这个时间点，怎么补请求头都拿不到 —— 服务端在验签阶段就 403 了。
enum LinkExpiry {

  /// 解析出的过期时间；读不到返回 nil。
  static func expiresAt(_ url: URL) -> Date? {
    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let keys = ["deadline", "expire", "expires", "x-expires", "e",
                "validity", "st", "timestamp"]
    for item in comps.queryItems ?? [] {
      guard let name = item.name.lowercased() as String?,
            keys.contains(name),
            let raw = item.value,
            let secs = Double(raw) else { continue }
      // 有的给毫秒
      let value = secs > 1e12 ? secs / 1000 : secs
      // 太小说明不是时间戳（比如 st=0）
      if value < 1_000_000_000 { continue }
      return Date(timeIntervalSince1970: value)
    }
    return nil
  }

  /// 剩余秒数。读不到过期时间时返回 nil。
  static func remaining(_ url: URL) -> TimeInterval? {
    guard let exp = expiresAt(url) else { return nil }
    return exp.timeIntervalSinceNow
  }

  /// 已经过期（或剩不到 3 秒）就返回 true。
  static func isExpired(_ url: URL) -> Bool {
    guard let left = remaining(url) else { return false }
    return left < 3
  }

  /// 给界面看的一句话。
  static func describe(_ url: URL) -> String? {
    guard let left = remaining(url) else { return nil }
    if left < 0 { return "已过期 \(Int(-left)) 秒" }
    if left < 60 { return "剩 \(Int(left)) 秒" }
    if left < 3600 { return "剩 \(Int(left / 60)) 分钟" }
    return "剩 \(Int(left / 3600)) 小时"
  }
}

// MARK: - 在页面里直接抓字节

/// 用已加载页面的 JS 环境 fetch 媒体，把字节流分块传回原生。
///
/// 为什么这是唯一可靠的办法：
///   CDN 直链带签名（deadline + sig），只在**签发时刻附近**有效。
///   用户从看到预览到点下载，往往已经过去几十秒。
///   而页面里 fetch 用的是：
///     - 同一会话（Cookie / TLS）
///     - 同一时刻（用户点下载那一刻）
///     - 浏览器原生请求（UA / Referer / sec-fetch-* 全自动）
///   所以只要链接还没过期，在页面里取一定成功；过期了就得先重抓。
@MainActor
final class WebViewFetcher: NSObject, ObservableObject {

  enum Failure: LocalizedError {
    case noWebView
    case badStatus(Int, String)
    case writeFailed(String)
    case jsError(String)
    case aborted

    var errorDescription: String? {
      switch self {
      case .noWebView:
        return "没有可用的浏览器页面。请先在探索页打开视频。"
      case .badStatus(let c, let b):
        return "页面内请求被拒（HTTP \(c)）\(b.isEmpty ? "" : "：\(b)")"
      case .writeFailed(let s):
        return "写入文件失败：\(s)"
      case .jsError(let s):
        return "页面内脚本出错：\(s)"
      case .aborted:
        return "已取消。"
      }
    }
  }

  /// 已收字节。
  @Published private(set) var received: Int64 = 0
  /// 总字节（页面给了 Content-Length 才有）。
  @Published private(set) var total: Int64 = 0
  @Published private(set) var running = false

  private var handler: ((Result<URL, Error>) -> Void)?
  private var fileHandle: FileHandle?
  private var dest: URL?
  private var started = false
  private var chunkCount = 0
  private var lastTick = Date()
  private var lastBytes: Int64 = 0
  private var onProgress: ((Int64, Int64) -> Void)?

  /// 开始抓取。
  ///
  /// - Parameter web: 已加载来源页的 WKWebView
  /// - Parameter url: 媒体直链
  /// - Parameter dest: 落地文件路径
  func fetch(using web: WKWebView,
             url: URL,
             to dest: URL,
             progress: ((Int64, Int64) -> Void)? = nil,
             completion: @escaping (Result<URL, Error>) -> Void) {

    cleanup()

    self.dest = dest
    self.handler = completion
    self.onProgress = progress
    self.received = 0
    self.total = 0
    self.started = false
    self.chunkCount = 0
    self.running = true

    let fm = FileManager.default
    try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    try? fm.removeItem(at: dest)
    guard fm.createFile(atPath: dest.path, contents: nil),
          let fh = try? FileHandle(forWritingTo: dest) else {
      finish(.failure(Failure.writeFailed("无法创建文件")))
      return
    }
    fileHandle = fh

    // 注册消息处理（幂等，重复注册会被替换）
    let ucc = web.configuration.userContentController
    ucc.removeScriptMessageHandler(forName: "tlFetch")
    ucc.add(self, name: "tlFetch")

    let js = Self.script(for: url.absoluteString)
    web.evaluateJavaScript(js) { [weak self] _, err in
      if let err {
        Task { @MainActor in
          self?.finish(.failure(Failure.jsError(err.localizedDescription)))
        }
      }
    }
  }

  /// 中止。
  func abort() {
    finish(.failure(Failure.aborted))
  }

  // MARK: 内部

  private func writeChunk(_ data: Data) {
    guard let fh = fileHandle else { return }
    do {
      try fh.write(contentsOf: data)
      received += Int64(data.count)
      chunkCount += 1
      // 每 4 块（约 2MB）报一次进度，避免过度刷新界面
      if chunkCount % 4 == 0 || total > 0 && received >= total {
        onProgress?(received, total)
      }
    } catch {
      finish(.failure(Failure.writeFailed(error.localizedDescription)))
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    guard running else { return }
    running = false

    try? fileHandle?.close()
    fileHandle = nil

    let cb = handler
    handler = nil
    onProgress = nil

    // 失败时删掉残缺文件
    if case .failure = result, let d = dest {
      try? FileManager.default.removeItem(at: d)
    }
    cb?(result)
  }

  private func cleanup() {
    try? fileHandle?.close()
    fileHandle = nil
    handler = nil
    onProgress = nil
    running = false
  }

  // MARK: JS

  /// 用 fetch + ReadableStream 流式读取，每块 base64 传回。
  ///
  /// base64 会让体积涨 33%，但 postMessage 只能传可序列化字符串，
  /// 分块控制内存峰值比省流量重要。512KB 一块 → base64 后约 683KB，
  /// 远低于 WKWebView 单条消息的限制。
  private static func script(for url: String) -> String {
    // 用 JSON 编码把 URL 安全嵌进去，避免引号/反斜杠破坏脚本
    let encoded = (try? JSONSerialization.data(withJSONObject: [url]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    let urlLiteral = String(encoded.dropFirst().dropLast())   // 去掉 []

    return """
    (function () {
      var TARGET = \(urlLiteral);
      var CHUNK = 512 * 1024;
      var post = function (m) {
        try { window.webkit.messageHandlers.tlFetch.postMessage(m); } catch (e) {}
      };

      var run = async function () {
        try {
          var resp = await fetch(TARGET, {
            credentials: 'include',
            mode: 'cors',
            cache: 'no-store'
          });

          if (!resp.ok) {
            var text = '';
            try { text = (await resp.text()).slice(0, 200); } catch (e) {}
            post({ type: 'fail', status: resp.status, body: text });
            return;
          }

          var total = 0;
          try { total = parseInt(resp.headers.get('content-length') || '0', 10) || 0; } catch (e) {}
          post({ type: 'start', total: total });

          if (!resp.body || !resp.body.getReader) {
            // 老 WebKit 没有流式 body：退化成一次性读
            var ab = await resp.arrayBuffer();
            var bytes = new Uint8Array(ab);
            for (var off = 0; off < bytes.length; off += CHUNK) {
              var piece = bytes.subarray(off, Math.min(off + CHUNK, bytes.length));
              post({ type: 'chunk', data: b64(piece) });
            }
            post({ type: 'end' });
            return;
          }

          var reader = resp.body.getReader();
          while (true) {
            var r = await reader.read();
            if (r.done) { break; }
            var v = r.value;
            if (!v || v.length === 0) { continue; }
            // 分片发送，单条消息不超过 CHUNK
            for (var i = 0; i < v.length; i += CHUNK) {
              post({ type: 'chunk', data: b64(v.subarray(i, Math.min(i + CHUNK, v.length))) });
            }
          }
          post({ type: 'end' });
        } catch (e) {
          post({ type: 'fail', status: 0, body: String(e) });
        }
      };

      var b64 = function (u8) {
        var s = '';
        var step = 8192;
        for (var i = 0; i < u8.length; i += step) {
          s += String.fromCharCode.apply(null, u8.subarray(i, Math.min(i + step, u8.length)));
        }
        return btoa(s);
      };

      run();
      return 'started';
    })();
    """
  }
}

extension WebViewFetcher: WKScriptMessageHandler {
  nonisolated func userContentController(_ ucc: WKUserContentController,
                                         didReceive message: WKScriptMessage) {
    guard message.name == "tlFetch",
          let body = message.body as? [String: Any],
          let type = body["type"] as? String else { return }

    switch type {
    case "start":
      let t = (body["total"] as? Int).map { Int64($0) } ?? 0
      Task { @MainActor in self.total = t }

    case "chunk":
      guard let s = body["data"] as? String, let data = Data(base64Encoded: s) else {
        Task { @MainActor in
          self.finish(.failure(Failure.jsError("分块解码失败")))
        }
        return
      }
      Task { @MainActor in self.writeChunk(data) }

    case "end":
      Task { @MainActor in
        guard let d = self.dest else {
          self.finish(.failure(Failure.writeFailed("目标路径丢失")))
          return
        }
        self.finish(.success(d))
      }

    case "fail":
      let status = body["status"] as? Int ?? 0
      let text = body["body"] as? String ?? ""
      Task { @MainActor in
        self.finish(.failure(Failure.badStatus(status, text)))
      }

    default:
      break
    }
  }
}
