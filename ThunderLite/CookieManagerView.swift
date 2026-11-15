import SwiftUI
import WebKit

// MARK: - Cookie 管理

/// 浏览器的登录态管理：用内置浏览器登录，Cookie 自动保存。
struct CookieManagerView: View {
  @EnvironmentObject private var prefs: Prefs
  @Environment(\.dismiss) private var dismiss

  @State private var showBrowser = false
  @State private var loginURL = "https://m.bilibili.com"
  @State private var showPrivacy = false
  @State private var cookies: [HTTPCookie] = []
  @State private var clearing = false

  var body: some View {
    ZStack {
      AuroraBackground()

      ScrollView {
        VStack(spacing: 22) {
          actionSection
          cookieListSection
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 40)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { topBar }
    .sheet(isPresented: $showBrowser) {
      LoginBrowserSheet(initialURL: loginURL)
        .onDisappear { reloadCookies() }
    }
    .sheet(isPresented: $showPrivacy) {
      PrivacyNoteSheet()
    }
    .onAppear { reloadCookies() }
  }

  // MARK: 顶栏

  private var topBar: some View {
    HStack {
      Button { dismiss() } label: {
        HStack(spacing: 3) {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .bold))
          Text("返回")
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(Theme.accent)
      }
      .buttonStyle(.plain)

      Spacer()

      Text("Cookie 管理（登录管理）")
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundColor(Theme.textPrimary)

      Spacer()

      // 占位，保持标题居中
      Color.clear.frame(width: 44, height: 1)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 14)
    .background(
      Theme.bgDeep.opacity(0.72)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(edges: .top)
    )
  }

  // MARK: 操作

  private var actionSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      VStack(spacing: 0) {
        Button { showPrivacy = true } label: {
          row(icon: "hand.raised", title: "隐私说明", tint: Theme.accent)
        }
        .buttonStyle(.plain)

        divider

        Button { showBrowser = true } label: {
          row(icon: "safari", title: "打开浏览器", tint: Theme.accent)
        }
        .buttonStyle(.plain)
      }
      .glassCard(radius: 16)

      Text("打开浏览器，登录网站，成功后 Cookie 信息会自动存储。此时可直接退出浏览器。")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.85))
        .padding(.leading, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func row(icon: String, title: String, tint: Color) -> some View {
    HStack(spacing: 13) {
      Image(systemName: icon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(tint)
        .frame(width: 26)

      Text(title)
        .font(.system(size: 15, weight: .medium))
        .foregroundColor(Theme.textPrimary)

      Spacer()
    }
    .padding(15)
    .contentShape(Rectangle())
  }

  // MARK: Cookie 列表

  private var cookieListSection: some View {
    VStack(alignment: .leading, spacing: 11) {
      VStack(spacing: 0) {
        Button {
          clearAllCookies()
        } label: {
          HStack(spacing: 13) {
            Image(systemName: "trash")
              .font(.system(size: 15, weight: .semibold))
              .foregroundColor(Theme.accent)
              .frame(width: 26)

            Text("清除所有 Cookie")
              .font(.system(size: 15, weight: .medium))
              .foregroundColor(Theme.textPrimary)

            Spacer()

            if clearing {
              ProgressView().tint(Theme.accent).scaleEffect(0.7)
            } else {
              Text("\(cookies.count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Theme.textTertiary)
            }
          }
          .padding(15)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if !cookies.isEmpty {
          divider
          ForEach(Array(domainGroups.enumerated()), id: \.element.domain) { idx, group in
            HStack(spacing: 10) {
              Circle()
                .fill(Theme.accent.opacity(0.5))
                .frame(width: 6, height: 6)

              VStack(alignment: .leading, spacing: 2) {
                Text(group.domain)
                  .font(.system(size: 12, weight: .medium))
                  .foregroundColor(Theme.textPrimary)
                  .lineLimit(1)
                Text("\(group.count) 条")
                  .font(.system(size: 10))
                  .foregroundColor(Theme.textTertiary)
              }

              Spacer()

              Button {
                deleteCookies(domain: group.domain)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .font(.system(size: 14))
                  .foregroundColor(Theme.textTertiary.opacity(0.7))
              }
              .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)

            if idx < domainGroups.count - 1 { divider }
          }
        }
      }
      .glassCard(radius: 16)
    }
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.055))
      .frame(height: 1)
      .padding(.leading, 15)
  }

  // MARK: 数据

  private struct DomainGroup {
    let domain: String
    let count: Int
  }

  private var domainGroups: [DomainGroup] {
    let grouped = Dictionary(grouping: cookies) { $0.domain }
    return grouped
      .map { DomainGroup(domain: $0.key, count: $0.value.count) }
      .sorted { $0.count > $1.count }
  }

  private func reloadCookies() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { list in
      DispatchQueue.main.async { cookies = list }
    }
  }

  private func clearAllCookies() {
    clearing = true
    let store = WKWebsiteDataStore.default()
    let types: Set<String> = [
      WKWebsiteDataTypeCookies,
      WKWebsiteDataTypeLocalStorage,
      WKWebsiteDataTypeSessionStorage,
      WKWebsiteDataTypeDiskCache,
      WKWebsiteDataTypeMemoryCache,
      WKWebsiteDataTypeWebSQLDatabases,
      WKWebsiteDataTypeIndexedDBDatabases,
    ]
    let all = WKWebsiteDataStore.allWebsiteDataTypes()
    store.removeData(ofTypes: all, modifiedSince: .distantPast) {
      DispatchQueue.main.async {
        clearing = false
        cookies = []
      }
    }
    // 同时清掉 URLSession 的共享存储
    HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    _ = types
  }

  private func deleteCookies(domain: String) {
    let targets = cookies.filter { $0.domain == domain }
    let store = WKWebsiteDataStore.default()
    let group = DispatchGroup()
    for c in targets {
      group.enter()
      store.httpCookieStore.delete(c) { group.leave() }
    }
    group.notify(queue: .main) {
      reloadCookies()
    }
  }
}

// MARK: - 登录浏览器

/// 登录用的简易浏览器：Cookie 由 WKWebsiteDataStore 自动持久化。
struct LoginBrowserSheet: View {
  let initialURL: String

  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @State private var target: URL
  @State private var progress: Double = 0
  @State private var title = ""
  @State private var canBack = false
  @State private var canFwd = false
  @State private var command: BrowserCommand?
  @State private var cookieCount = 0

  init(initialURL: String) {
    self.initialURL = initialURL
    _target = State(initialValue: URL(string: initialURL) ?? URL(string: "about:blank")!)
    _address = State(initialValue: initialURL)
  }

  var body: some View {
    ZStack {
      Theme.bgDeep.ignoresSafeArea()

      VStack(spacing: 0) {
        // 顶栏
        HStack {
          Button { dismiss() } label: {
            Text("完成")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(Theme.accent)
          }
          .buttonStyle(.plain)

          Spacer()

          VStack(spacing: 1) {
            Text(title.isEmpty ? "登录" : title)
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(Theme.textPrimary)
              .lineLimit(1)
            if cookieCount > 0 {
              Text("\(cookieCount) 个 Cookie 已保存")
                .font(.system(size: 9))
                .foregroundColor(Color(hex: 0x35E08A))
            }
          }

          Spacer()

          Button { cookeysRefresh() } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(Theme.textSecondary)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bgElevated)

        // 地址栏
        HStack(spacing: 8) {
          Button { command = .back } label: {
            Image(systemName: "chevron.left")
              .font(.system(size: 12, weight: .bold))
              .foregroundColor(canBack ? Theme.textPrimary : Theme.textTertiary)
          }
          .buttonStyle(.plain)
          .disabled(!canBack)

          TextField("", text: $address)
            .font(.system(size: 12))
            .foregroundColor(Theme.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit { go() }
            .accentColor(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06))
            )

          Button { command = .forward } label: {
            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .bold))
              .foregroundColor(canFwd ? Theme.textPrimary : Theme.textTertiary)
          }
          .buttonStyle(.plain)
          .disabled(!canFwd)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgElevated)

        if progress > 0 && progress < 1 {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(Theme.accent)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
        }

        SnifferWebView(store: placeholderStore,
                       url: target,
                       progress: $progress,
                       pageTitle: $title,
                       canGoBack: $canBack,
                       canGoForward: $canFwd,
                       command: $command)
      }
    }
    .onAppear { cookeysRefresh() }
  }

  /// 登录页不需要嗅探，但复用同一个封装，给个临时 store 即可。
  @StateObject private var placeholderStore = SnifferStore()

  private func go() {
    var t = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    if !t.lowercased().hasPrefix("http") { t = "https://" + t }
    if let u = URL(string: t) { target = u }
  }

  private func cookeysRefresh() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { list in
      DispatchQueue.main.async { cookieCount = list.count }
    }
  }
}

// MARK: - 隐私说明

struct PrivacyNoteSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      AuroraBackground()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
              .font(.system(size: 20))
              .foregroundColor(Theme.accent)
            Text("隐私说明")
              .font(.system(size: 18, weight: .bold, design: .rounded))
              .foregroundColor(Theme.textPrimary)
          }

          note("Cookie 存在哪里", "全部保存在本机 App 沙盒内的 WKWebsiteDataStore，不上传任何服务器。卸载 App 即随之删除。")

          note("浏览器做什么", "内置浏览器只用于登录网站并保留会话。所有页面访问都直接由你的设备发出，不经过任何中转。")

          note("嗅探会看到什么", "资源嗅探在页面内运行，读取的只是当前网页自己请求的视频、图片、音频地址。不做跨站跟踪，不收集浏览历史。")

          note("广告拦截", "拦截列表是本机硬编码的域名清单，不做云端同步，也不会把访问记录发出去。")

          note("下载的文件", "存在你选择的目录（App 沙盒 Documents 或 /var/mobile/Downloads），不会自动上传。")

          Spacer(minLength: 20)
        }
        .padding(20)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack {
        Spacer()
        Button { dismiss() } label: {
          Text("知道了")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.bgDeep)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.accentGradient))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(
        Theme.bgDeep.opacity(0.72)
          .background(.ultraThinMaterial)
          .ignoresSafeArea(edges: .top)
      )
    }
  }

  private func note(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(Theme.textPrimary)
      Text(text)
        .font(.system(size: 11))
        .foregroundColor(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .glassCard(radius: 14)
  }
}
