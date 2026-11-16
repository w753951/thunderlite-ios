import Foundation
import WebKit
import UIKit

// MARK: - 缓存清理

/// 一键清理各类缓存。分项统计大小，让用户知道清掉了什么。
@MainActor
final class CacheCleaner: ObservableObject {
  static let shared = CacheCleaner()

  struct Item: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    var bytes: Int64
    let action: () async -> Void
  }

  @Published private(set) var items: [Item] = []
  @Published private(set) var scanning = false
  @Published private(set) var clearing = false
  @Published private(set) var lastCleared: Int64 = 0

  var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

  private init() {}

  // MARK: 扫描

  func scan() {
    scanning = true
    Task {
      let list = await buildItems()
      items = list
      scanning = false
    }
  }

  /// 构建分项清单（异步，因为 WebKit 那边是回调式）。
  private func buildItems() async -> [Item] {
    var list: [Item] = []

    // 1) WebKit 网站数据（Cookie 之外的部分）
    let webBytes = await webKitCacheSize()
    list.append(Item(
      name: "浏览器缓存",
      detail: "网页图片、脚本、本地存储",
      bytes: webBytes,
      action: { await Self.clearWebKitCache() }))

    // 2) URLSession 的磁盘缓存
    let urlBytes = Self.directorySize(Self.urlCacheDir())
    list.append(Item(
      name: "网络请求缓存",
      detail: "会话级 HTTP 缓存",
      bytes: urlBytes,
      action: {
        URLCache.shared.removeAllCachedResponses()
        try? FileManager.default.removeItem(at: Self.urlCacheDir())
      }))

    // 3) App 临时目录
    let tmpBytes = Self.directorySize(FileManager.default.temporaryDirectory)
    list.append(Item(
      name: "临时文件",
      detail: "下载分块、转码中间产物",
      bytes: tmpBytes,
      action: {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        if let names = try? fm.contentsOfDirectory(atPath: tmp.path) {
          for n in names {
            try? fm.removeItem(at: tmp.appendingPathComponent(n))
          }
        }
      }))

    // 4) 缩略图/图标缓存
    let thumbBytes = Self.directorySize(Self.thumbnailDir())
    list.append(Item(
      name: "缩略图缓存",
      detail: "预览页与列表的小图",
      bytes: thumbBytes,
      action: {
        try? FileManager.default.removeItem(at: Self.thumbnailDir())
      }))

    // 5) 运行日志
    let logBytes = Self.directorySize(Self.logDir())
    list.append(Item(
      name: "运行日志",
      detail: "诊断与崩溃记录",
      bytes: logBytes,
      action: {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: Self.logDir().path) {
          for n in names {
            try? fm.removeItem(at: Self.logDir().appendingPathComponent(n))
          }
        }
      }))

    return list
  }

  // MARK: 清理

  /// 逐项清理，返回总共释放的字节数。
  func clearAll() async -> Int64 {
    clearing = true
    let before = totalBytes

    for item in items {
      await item.action()
    }

    // 重新扫描一次，用前后的差值算真实释放量
    items = await buildItems()
    let after = totalBytes
    lastCleared = max(0, before - after)
    clearing = false
    return lastCleared
  }

  /// 只清某一项。
  func clear(_ item: Item) async -> Int64 {
    let size = item.bytes
    await item.action()
    items = await buildItems()
    return size
  }

  // MARK: 路径

  private static func urlCacheDir() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("ThunderLiteURLCache", isDirectory: true)
  }

  private static func thumbnailDir() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("ThunderLiteThumbs", isDirectory: true)
  }

  private static func logDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("ThunderLite/Logs", isDirectory: true)
  }

  private static func directorySize(_ url: URL) -> Int64 {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: url,
                                 includingPropertiesForKeys: [.fileSizeKey],
                                 options: [.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0
    for case let f as URL in en {
      if let v = try? f.resourceValues(forKeys: [.fileSizeKey]),
         let s = v.fileSize {
        total += Int64(s)
      }
    }
    return total
  }

  // MARK: WebKit

  private func webKitCacheSize() async -> Int64 {
    await withCheckedContinuation { cont in
      WKWebsiteDataStore.default().fetchDataRecords(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
        var total: Int64 = 0
        for r in records {
          // 只统计非 Cookie 的部分（Cookie 归 Cookie 管理页管）
          if r.dataTypes.contains(WKWebsiteDataTypeDiskCache)
              || r.dataTypes.contains(WKWebsiteDataTypeMemoryCache)
              || r.dataTypes.contains(WKWebsiteDataTypeOfflineWebApplicationCache) {
            total += 1024 * 16   // WebKit 不暴露精确大小，按记录数粗估
          }
        }
        cont.resume(returning: total)
      }
    }
  }

  /// 只清 WebKit 的缓存，保留 Cookie / localStorage（不然登录态没了）。
  private static func clearWebKitCache() async {
    let types: Set<String> = [
      WKWebsiteDataTypeDiskCache,
      WKWebsiteDataTypeMemoryCache,
      WKWebsiteDataTypeOfflineWebApplicationCache,
    ]
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      WKWebsiteDataStore.default().removeData(ofTypes: types,
                                              modifiedSince: .distantPast) {
        cont.resume()
      }
    }
    URLCache.shared.removeAllCachedResponses()
  }

  // MARK: 格式化

  static func sizeText(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB"]
    var v = Double(bytes)
    var i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
  }
}
