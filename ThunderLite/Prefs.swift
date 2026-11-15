import Foundation

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

  private var cookieStore: [String: String]

  private init() {
    useSystemDownloads = defaults.bool(forKey: Key.useSystemDownloads)
    let saved = defaults.integer(forKey: Key.threads)
    threads = saved == 0 ? 32 : max(1, min(32, saved))
    keepAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
    cookieStore = defaults.dictionary(forKey: Key.cookies) as? [String: String] ?? [:]
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
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { cookieStore.removeValue(forKey: siteKey) }
    else { cookieStore[siteKey] = text }
    defaults.set(cookieStore, forKey: Key.cookies)
    objectWillChange.send()
  }

  func cookieLength(for siteKey: String) -> Int {
    cookie(for: siteKey)?.count ?? 0
  }

  var hasAnyCookie: Bool { !cookieStore.isEmpty }
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
