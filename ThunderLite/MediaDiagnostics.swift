import SwiftUI
import UIKit

// MARK: - 下载诊断

/// 对某个媒体地址做一次真实请求，把状态码、响应头、响应体前若干字节全列出来。
///
/// 用途：403/超时这类问题只看「失败」两个字没法定位，必须知道服务器到底回了什么
/// （是真的拒绝、还是重定向到登录页、还是返回了很小的错误 JSON）。
@MainActor
final class MediaDiagnostics: ObservableObject {

  struct Attempt: Identifiable {
    let id = UUID()
    let title: String
    let status: String          // "200" / "403" / "超时" / "错误"
    let mime: String
    let length: String
    let headers: [String]
    let bodyPreview: String
    let elapsed: String
    var ok: Bool { status.hasPrefix("2") }
  }

  @Published private(set) var attempts: [Attempt] = []
  @Published private(set) var running = false
  @Published private(set) var verdict: String = ""

  /// 依次用几种不同的请求配置去试，看哪种能通。
  func run(url: URL, referer: String?, userAgent: String?) {
    attempts = []
    verdict = "正在测试…"
    running = true

    Task {
      // 1) 裸请求（只有 URL）
      await probe(url: url, label: "① 裸请求（无任何头）",
                  headers: [:])

      // 2) 只加 UA
      if let ua = userAgent {
        await probe(url: url, label: "② + 浏览器 UA",
                    headers: ["User-Agent": ua])
      }

      // 3) 加 UA + Referer
      var h3: [String: String] = [:]
      if let ua = userAgent { h3["User-Agent"] = ua }
      if let r = referer { h3["Referer"] = r }
      await probe(url: url, label: "③ + UA + Referer", headers: h3)

      // 4) 全套（含 WebView Cookie）
      let full = MediaRequestHeaders.build(for: url)
      await probe(url: url, label: "④ + UA + Referer + Cookie", headers: full)

      // 5) 用 Range 请求（下载引擎实际用的是这个）
      var h5 = full
      h5["Range"] = "bytes=0-0"
      await probe(url: url, label: "⑤ 全套 + Range: bytes=0-0", headers: h5)

      // 结论
      let passing = attempts.filter { $0.ok }
      if passing.isEmpty {
        verdict = "全部失败：这个地址在当前会话下拿不到。可能已过期，需要在原页面重新嗅探。"
      } else if let first = accounts(passing) {
        verdict = "可用配置：\(first.title)。建议按这个配置重试。"
      } else {
        verdict = "有 \(passing.count) 种配置成功。"
      }
      running = false
    }
  }

  private func accounts(_ list: [Attempt]) -> Attempt? {
    // 取最后一个成功的（headers 最全的那个通常最稳）
    list.last
  }

  private func probe(url: URL,
                     label: String,
                     headers: [String: String]) async {
    let start = Date()
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "GET"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 15
    cfg.httpShouldSetCookies = false
    let session = URLSession(configuration: cfg)

    var attempt: Attempt
    do {
      let (data, resp) = try await session.data(for: req)
      let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
      let http = resp as? HTTPURLResponse
      let status = http.map { "\($0.statusCode)" } ?? "无状态码"
      let mime = (http?.mimeType ?? "?")
      let len = http.map { h in
        h.expectedContentLength > 0 ? "\(h.expectedContentLength) B" : "未知"
      } ?? "?"

      var headerLines: [String] = []
      if let all = http?.allHeaderFields {
        for (k, v) in all.sorted(by: { "\($0.key)" < "\($1.key)" }) {
          headerLines.append("\(k): \(v)")
        }
      }

      let body = data.prefix(200)
      let bodyText: String
      if let s = String(data: body, encoding: .utf8) {
        bodyText = s.replacingOccurrences(of: "\n", with: " ")
      } else {
        bodyText = body.map { String(format: "%02x", $0) }.joined(separator: " ")
      }

      attempt = Attempt(title: label, status: status, mime: mime,
                        length: len, headers: headerLines,
                        bodyPreview: bodyText.isEmpty ? "（空）" : bodyText,
                        elapsed: elapsed)
    } catch {
      let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))
      let ns = error as NSError
      attempt = Attempt(title: label,
                        status: "错误 \(ns.code)",
                        mime: "-",
                        length: "-",
                        headers: ["\(ns.domain): \(ns.localizedDescription)"],
                        bodyPreview: "-",
                        elapsed: elapsed)
    }

    attempts.append(attempt)
  }
}

// MARK: - 诊断界面

struct MediaDiagnosticsSheet: View {
  let media: SniffedMedia
  @StateObject private var diag = MediaDiagnostics()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      AuroraBackground()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // 地址
          VStack(alignment: .leading, spacing: 6) {
            Text("诊断目标")
              .font(.system(size: 11, weight: .bold))
              .tracking(1.4)
              .foregroundColor(Theme.textTertiary)
            Text(media.url.absoluteString)
              .font(.system(size: 10, design: .monospaced))
              .foregroundColor(Theme.textSecondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .glassCard(radius: 14)

          // 结论
          if !diag.verdict.isEmpty {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: diag.verdict.contains("可用")
                    ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
              Text(diag.verdict)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
            .foregroundColor(diag.verdict.contains("可用")
                             ? Color(hex: 0x35E08A) : Theme.accentWarm)
            .padding(13)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((diag.verdict.contains("可用")
                       ? Color(hex: 0x35E08A) : Theme.accentWarm).opacity(0.10))
            )
          }

          // 每种尝试
          ForEach(diag.attempts) { a in
            attemptCard(a)
          }

          if diag.running {
            HStack(spacing: 9) {
              ProgressView().tint(Theme.accent).scaleEffect(0.8)
              Text("测试中…")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
            }
            .padding(.leading, 4)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 36)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack {
        Text("下载诊断")
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundColor(Theme.textPrimary)
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Theme.textSecondary)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 18)
      .padding(.top, 8)
      .padding(.bottom, 12)
      .background(
        Theme.bgDeep.opacity(0.72)
          .background(.ultraThinMaterial)
          .ignoresSafeArea(edges: .top)
      )
    }
    .onAppear {
      diag.run(url: media.url,
               referer: MediaRequestHeaders.referer(for: media.url),
               userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                 + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
    }
  }

  private func attemptCard(_ a: MediaDiagnostics.Attempt) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle()
          .fill(a.ok ? Color(hex: 0x35E08A) : Color(hex: 0xFF5E6E))
          .frame(width: 7, height: 7)
        Text(a.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(Theme.textPrimary)
        Spacer(minLength: 4)
        Text(a.status)
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundColor(a.ok ? Color(hex: 0x35E08A) : Color(hex: 0xFF5E6E))
        Text(a.elapsed)
          .font(.system(size: 9))
          .foregroundColor(Theme.textTertiary)
      }

      HStack(spacing: 10) {
        Text("MIME: \(a.mime)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(Theme.textTertiary)
        Text("大小: \(a.length)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(Theme.textTertiary)
      }

      if !a.headers.isEmpty {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(a.headers.prefix(12).enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(size: 9, design: .monospaced))
              .foregroundColor(Theme.textSecondary.opacity(0.85))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }

      if a.bodyPreview != "-" && !a.bodyPreview.isEmpty {
        Text("Body: \(a.bodyPreview)")
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(Theme.accentWarm.opacity(0.9))
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .glassCard(radius: 12)
  }
}
