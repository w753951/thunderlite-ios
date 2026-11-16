import Foundation
import UIKit
import Combine

/// 下载目录与网盘 Cookie 的偏好设置。
///
/// 保存位置有两档：
///   - 沙盒内 Documents：任何设备都能用，接上「文件」App 就能看到。
///   - `/var/mobile/Downloads`：越狱设备可写，也就是系统级的「下载」目录。
///     写不进去就自动退回 Documents，不会让用户卡住。
@MainActor
final class Prefs: ObservableObject {
  static let shared = Prefs()

  private let defaults = UserDefaults.standard

  private enum Key {
    static let useSystemDownloads = "useSystemDownloads"
    static let threads = "threads"
    static let keepAwake = "keepAwake"
    static let cookies = "netdiskCookies"
    static let forcedCookies = "forceCookieSites"

    // 任务设置
    static let maxConcurrentTasks = "maxConcurrentTasks"
    static let autoSelectEnabled = "autoSelectEnabled"
    static let autoSelectVideoHeight = "autoSelectVideoHeight"
    static let autoSelectAudio = "autoSelectAudio"
    static let autoSelectImage = "autoSelectImage"
    static let transcodeVideo = "transcodeVideo"
    static let transcodeAudio = "transcodeAudio"
    static let autoSaveAfterDone = "autoSaveAfterDone"
    static let autoSaveTarget = "autoSaveTarget"

    // 浏览器
    static let adBlockEnabled = "adBlockEnabled"
    static let acceptableAdsEnabled = "acceptableAdsEnabled"
    static let emulateDevice = "emulateDevice"
  }

  /// 越狱设备写到 /var/mobile/Downloads。
  @Published var useSystemDownloads: Bool {
    didSet { defaults.set(useSystemDownloads, forKey: Key.useSystemDownloads) }
  }

  /// 1...32
  @Published var threads: Int {
    didSet { defaults.set(threads, forKey: Key.threads) }
  }

  /// 下载中保持屏幕常亮（只在 App 前台时有效）。
  @Published var keepAwake: Bool {
    didSet { defaults.set(keepAwake, forKey: Key.keepAwake) }
  }

  // MARK: - 任务设置

  /// 同时进行的任务数上限。0 表示不限（Max）。
  @Published var maxConcurrentTasks: Int {
    didSet { defaults.set(maxConcurrentTasks, forKey: Key.maxConcurrentTasks) }
  }

  /// 批量抓取时自动挑最高可用清晰度。
  @Published var autoSelectEnabled: Bool {
    didSet { defaults.set(autoSelectEnabled, forKey: Key.autoSelectEnabled) }
  }

  /// 自动选择的目标清晰度上限：720 / 1080 / 2160 / 0=最高。
  @Published var autoSelectVideoHeight: Int {
    didSet { defaults.set(autoSelectVideoHeight, forKey: Key.autoSelectVideoHeight) }
  }

  @Published var autoSelectAudio: Bool {
    didSet { defaults.set(autoSelectAudio, forKey: Key.autoSelectAudio) }
  }

  @Published var autoSelectImage: Bool {
    didSet { defaults.set(autoSelectImage, forKey: Key.autoSelectImage) }
  }

  /// 完成后自动转码：视频统一成 mp4(H.264)，音频统一成 m4a。
  @Published var transcodeVideo: Bool {
    didSet { defaults.set(transcodeVideo, forKey: Key.transcodeVideo) }
  }

  @Published var transcodeAudio: Bool {
    didSet { defaults.set(transcodeAudio, forKey: Key.transcodeAudio) }
  }

  /// 完成后自动转存到相册。
  @Published var autoSaveAfterDone: Bool {
    didSet { defaults.set(autoSaveAfterDone, forKey: Key.autoSaveAfterDone) }
  }

  /// 转存目标：photos / files / both
  @Published var autoSaveTarget: String {
    didSet { defaults.set(autoSaveTarget, forKey: Key.autoSaveTarget) }
  }

  // MARK: - 浏览器

  @Published var adBlockEnabled: Bool {
    didSet {
      defaults.set(adBlockEnabled, forKey: Key.adBlockEnabled)
      rebuildAdBlock()
    }
  }

  @Published var acceptableAdsEnabled: Bool {
    didSet {
      defaults.set(acceptableAdsEnabled, forKey: Key.acceptableAdsEnabled)
      rebuildAdBlock()
    }
  }

  /// 模拟终端设备：phone / tablet / desktop
  @Published var emulateDevice: String {
    didSet { defaults.set(emulateDevice, forKey: Key.emulateDevice) }
  }

  /// 规则重编译计数器，界面可监听它来确认生效。
  @Published private(set) var adBlockVersion: Int = 0

  private func rebuildAdBlock() {
    guard adBlockEnabled else {
      AdBlocker.clearCache()
      adBlockVersion += 1
      return
    }
    AdBlocker.compile(allowAcceptable: acceptableAdsEnabled) { [weak self] ok in
      guard let self else { return }
      self.adBlockVersion += 1
    }
  }

  /// 给 webview 用的模拟 UA。
  var emulatedUserAgent: String? {
    switch emulateDevice {
    case "tablet":
      return "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    case "desktop":
      return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    default:
      return nil   // nil = 用系统默认（iPhone）
    }
  }

  private var cookieStore: [String: String]

  /// 默认不带 Cookie 的站点（夸克、UC）。用户如果明确要求带，记在这里。
  ///
  /// 背景：这两个网盘在 thunder-lite 上实测「带登录 Cookie 反而被按账号限速到
  /// ~130 KB/s」，所以默认丢掉。但不是所有人都这样，有些文件和账号必须带 Cookie
  /// 才能下，所以给一个显式开关，别把路堵死。
  private var forceCookieStore: Set<String>

  private init() {
    useSystemDownloads = defaults.bool(forKey: Key.useSystemDownloads)
    let saved = defaults.integer(forKey: Key.threads)
    threads = saved == 0 ? 32 : max(1, min(32, saved))
    keepAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
    cookieStore = defaults.dictionary(forKey: Key.cookies) as? [String: String] ?? [:]
    forceCookieStore = Set(defaults.stringArray(forKey: Key.forcedCookies) ?? [])

    maxConcurrentTasks = defaults.object(forKey: Key.maxConcurrentTasks) as? Int ?? 0
    autoSelectEnabled = defaults.object(forKey: Key.autoSelectEnabled) as? Bool ?? true
    let h = defaults.integer(forKey: Key.autoSelectVideoHeight)
    autoSelectVideoHeight = h == 0 ? 1080 : h
    autoSelectAudio = defaults.object(forKey: Key.autoSelectAudio) as? Bool ?? true
    autoSelectImage = defaults.object(forKey: Key.autoSelectImage) as? Bool ?? false
    transcodeVideo = defaults.object(forKey: Key.transcodeVideo) as? Bool ?? false
    transcodeAudio = defaults.object(forKey: Key.transcodeAudio) as? Bool ?? false
    autoSaveAfterDone = defaults.object(forKey: Key.autoSaveAfterDone) as? Bool ?? false
    autoSaveTarget = defaults.string(forKey: Key.autoSaveTarget) ?? "photos"

    adBlockEnabled = defaults.object(forKey: Key.adBlockEnabled) as? Bool ?? true
    acceptableAdsEnabled = defaults.object(forKey: Key.acceptableAdsEnabled) as? Bool ?? false
    emulateDevice = defaults.string(forKey: Key.emulateDevice) ?? "phone"

    // 启动时把拦截规则编译好（首次编译要几百毫秒，这里异步做）
    if adBlockEnabled {
      AdBlocker.compile(allowAcceptable: acceptableAdsEnabled) { _ in }
    }
  }

  // MARK: - 下载目录

  /// 系统级 Downloads 是否真的可写。越狱设备为 true，普通设备为 false。
  var systemDownloadsAvailable: Bool {
    let dir = URL(fileURLWithPath: "/var/mobile/Downloads")
    return FileManager.default.isWritableFile(atPath: dir.deletingLastPathComponent().path)
  }

  /// 当前实际要用的保存目录，保证已创建。
  func saveDirectory() -> URL {
    let fm = FileManager.default
    if useSystemDownloads {
      let system = URL(fileURLWithPath: "/var/mobile/Downloads", isDirectory: true)
      if (try? fm.createDirectory(at: system, withIntermediateDirectories: true)) != nil,
         fm.isWritableFile(atPath: system.path) {
        return system
      }
      // 写不进去就退回沙盒，不让下载失败。
    }
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
    return docs
  }

  /// 给界面显示用的目录描述。
  func saveDirectoryLabel() -> String {
    saveDirectory().path
  }

  // MARK: - 网盘 Cookie

  func cookie(for siteKey: String) -> String? {
    let value = cookieStore[siteKey]
    return (value?.isEmpty ?? true) ? nil : value
  }

  func setCookie(_ value: String, for siteKey: String) {
    let text = Self.normalizeCookie(value)
    if text.isEmpty { cookieStore.removeValue(forKey: siteKey) }
    else { cookieStore[siteKey] = text }
    defaults.set(cookieStore, forKey: Key.cookies)
    objectWillChange.send()
  }

  /// 把用户粘贴进来的内容收拾成能直接塞进请求头的单行 Cookie。
  ///
  /// 常见的三种粘法都要能吃：
  ///   - 整条请求头：`Cookie: __puus=xxx; __pus=yyy`
  ///   - 多行（DevTools 复制会带换行）
  ///   - 首尾多余空白 / 引号
  /// HTTP 头里不允许出现换行，留着会直接让 URLSession 抛错。
  static func normalizeCookie(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // 去掉误粘进来的字段名
    if let r = text.range(of: "cookie:", options: [.caseInsensitive, .anchored]) {
      text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    // 掐掉常见的尾部噪声
    for tail in [";", "\"", "'"] where text.hasSuffix(tail) {
      text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
    }
    if text.hasPrefix("\"") || text.hasPrefix("'") {
      text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    // 连续空白压成一个空格
    while text.contains("  ") {
      text = text.replacingOccurrences(of: "  ", with: " ")
    }
    return text
  }

  func cookieLength(for siteKey: String) -> Int {
    cookie(for: siteKey)?.count ?? 0
  }

  var hasAnyCookie: Bool { !cookieStore.isEmpty }

  // MARK: - 强制带 Cookie（夸克 / UC）

  /// 该站点是否强制发送 Cookie。
  func isCookieForced(for siteKey: String) -> Bool {
    forceCookieStore.contains(siteKey)
  }

  func setCookieForced(_ forced: Bool, for siteKey: String) {
    if forced { forceCookieStore.insert(siteKey) }
    else { forceCookieStore.remove(siteKey) }
    defaults.set(Array(forceCookieStore), forKey: Key.forcedCookies)
    objectWillChange.send()
  }
}

/// 屏幕常亮。
///
/// iOS 上 `isIdleTimerDisabled` 必须在主线程改；工程启用 UIScene 时
/// 生命周期以 scene 为准（见 SceneDelegate）。
enum KeepAwake {
  @MainActor
  static func set(_ on: Bool) {
    guard UIApplication.shared.isIdleTimerDisabled != on else { return }
    UIApplication.shared.isIdleTimerDisabled = on
  }
}
