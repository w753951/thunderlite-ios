import SwiftUI
import UIKit

struct SettingsView: View {
  @EnvironmentObject private var prefs: Prefs
  @Environment(\.dismiss) private var dismiss

  @State private var editingSite: NetdiskSite?

  var body: some View {
    NavigationView {
      ZStack {
        AuroraBackground()

        ScrollView {
          VStack(spacing: 20) {
            navSection
            downloadSection
            browserSection
            netdiskSection
            aboutSection
          }
          .padding(.horizontal, 20)
          .padding(.top, 8)
          .padding(.bottom, 40)
        }
      }
      .navigationBarHidden(true)
    }
    .navigationViewStyle(.stack)
    .safeAreaInset(edge: .top, spacing: 0) { topBar }
    .sheet(item: $editingSite) { site in
      CookieSheet(site: site).environmentObject(prefs)
    }
    .onAppear {
      // 让「清理缓存」入口显示当前占用
      if CacheCleaner.shared.items.isEmpty {
        CacheCleaner.shared.scan()
      }
    }
  }

  // MARK: 顶栏

  private var topBar: some View {
    HStack {
      Text("设置")
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .foregroundColor(Theme.textPrimary)
      Spacer()
      Button { dismiss() } label: {
        Text("完成")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(Theme.bgDeep)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Capsule().fill(Theme.accentGradient))
          .shadow(color: Theme.accent.opacity(0.35), radius: 9, x: 0, y: 3)
      }
      .buttonStyle(.plain)
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

  // MARK: 分区标题

  private func sectionLabel(_ text: String) -> some View {
    HStack(spacing: 7) {
      Rectangle()
        .fill(Theme.accentGradient)
        .frame(width: 2.5, height: 11)
        .clipShape(Capsule())
      Text(text)
        .font(.system(size: 11, weight: .bold))
        .tracking(1.6)
        .foregroundColor(Theme.textTertiary)
      Spacer()
    }
  }

  // MARK: 下载

  private var navSection: some View {
    VStack(spacing: 0) {
      NavigationLink { TaskSettingsView() } label: {
        HStack(spacing: 12) {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Theme.accent)
            .frame(width: 26)
          Text("任务设置")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textPrimary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.textTertiary)
        }
        .padding(15)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      divider

      NavigationLink { CookieManagerView() } label: {
        HStack(spacing: 12) {
          Image(systemName: "key.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Theme.accent)
            .frame(width: 26)
          Text("Cookie 管理")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textPrimary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.textTertiary)
        }
        .padding(15)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      divider

      NavigationLink { CacheCleanerView() } label: {
        HStack(spacing: 12) {
          Image(systemName: "trash.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(Theme.accent)
            .frame(width: 26)
          Text("清理缓存")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Theme.textPrimary)
          Spacer()
          Text(CacheCleaner.sizeText(CacheCleaner.shared.totalBytes))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(Theme.textTertiary)
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.textTertiary)
        }
        .padding(15)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .glassCard(radius: 16)
  }

  // MARK: 浏览器

  private var browserSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel("浏览器")

      VStack(spacing: 0) {
        Toggle(isOn: $prefs.adBlockEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("启用广告拦截")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(Theme.textPrimary)
            Text("已拦截：\(AdBlockStore.shared.blockedCount)")
              .font(.system(size: 11))
              .foregroundColor(Theme.accentWarm)
          }
        }
        .tint(Theme.accent)
        .padding(14)

        divider

        Toggle(isOn: $prefs.acceptableAdsEnabled) {
          Text("可接受的广告")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .padding(14)
        .disabled(!prefs.adBlockEnabled)
      }
      .glassCard(radius: 16)

      Text("一些非侵入式广告将加入白名单，以支持关注用户并提供最佳内容的网站。")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.85))
        .padding(.leading, 4)
        .fixedSize(horizontal: false, vertical: true)

      // 模拟终端设备
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text("模拟终端设备")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Theme.textPrimary)
          Spacer()
          HStack(spacing: 2) {
            deviceButton("iphone", "phone")
            deviceButton("ipad", "tablet")
            deviceButton("desktopcomputer", "desktop")
          }
          .padding(3)
          .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .padding(14)
      }
      .glassCard(radius: 16)
    }
  }

  private func deviceButton(_ symbol: String, _ value: String) -> some View {
    Button { prefs.emulateDevice = value } label: {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(prefs.emulateDevice == value ? Theme.bgDeep : Theme.textSecondary)
        .frame(width: 34, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(prefs.emulateDevice == value ? Color.white.opacity(0.92) : Color.clear)
        )
    }
    .buttonStyle(.plain)
  }

  private var downloadSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel("下载")

      VStack(spacing: 0) {
        // 线程数
        VStack(alignment: .leading, spacing: 11) {
          HStack {
            Text("线程数")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(Theme.textPrimary)
            Spacer()
            Text("\(prefs.threads)")
              .font(.system(size: 15, weight: .bold, design: .rounded))
              .monospacedDigit()
              .foregroundColor(Theme.accent)
          }

          Slider(
            value: Binding(
              get: { Double(prefs.threads) },
              set: { prefs.threads = Int($0.rounded()) }
            ),
            in: 1...32,
            step: 1
          )
          .accentColor(Theme.accent)

          Text("网盘会自动收窄并发：夸克 32、百度 8、阿里 4 —— 开太高会被 CDN 限流。")
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)

        divider

        // 系统 Downloads
        settingToggle(
          title: "存到系统 Downloads",
          subtitle: prefs.systemDownloadsAvailable
            ? "/var/mobile/Downloads"
            : "本机不可写，会自动用 App 目录",
          isOn: $prefs.useSystemDownloads,
          enabled: prefs.systemDownloadsAvailable)

        divider

        settingToggle(
          title: "下载时保持屏幕常亮",
          subtitle: nil,
          isOn: $prefs.keepAwake,
          enabled: true)

        divider

        // 当前目录
        Button { DirOpener.open(prefs.saveDirectory()) } label: {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("当前目录")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textPrimary)
              Text(prefs.saveDirectoryLabel())
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.forward.app")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(Theme.accent)
          }
          .padding(14)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .glassCard(radius: 16)

      Text("点「当前目录」会在 Filza 里打开这个文件夹；没装 Filza 就退回「文件」App。")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.8))
        .padding(.leading, 4)
    }
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.055))
      .frame(height: 1)
      .padding(.leading, 14)
  }

  private func settingToggle(title: String, subtitle: String?,
                             isOn: Binding<Bool>, enabled: Bool) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(enabled ? Theme.textPrimary : Theme.textTertiary)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundColor(Theme.textTertiary)
        }
      }
    }
    .tint(Theme.accent)
    .padding(14)
    .disabled(!enabled)
  }

  // MARK: 网盘

  private var netdiskSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel("网盘")

      VStack(spacing: 0) {
        ForEach(Array(NetdiskSupport.sites.enumerated()), id: \.element.key) { idx, site in
          Button { editingSite = site } label: {
            HStack(spacing: 11) {
              // 站点色点
              Circle()
                .fill(Color(hex: site.color))
                .frame(width: 9, height: 9)
                .shadow(color: Color(hex: site.color).opacity(0.6), radius: 5, x: 0, y: 0)

              VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(Theme.textPrimary)
                Text(cookieHint(site))
                  .font(.system(size: 10))
                  .foregroundColor(Theme.textTertiary)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }

              Spacer(minLength: 8)

              if site.sendCookie || prefs.cookieLength(for: site.key) > 0 {
                let filled = prefs.cookieLength(for: site.key) > 0
                Text(filled ? "已填" : "未填")
                  .font(.system(size: 9, weight: .bold))
                  .padding(.horizontal, 7)
                  .padding(.vertical, 3)
                  .background(
                    Capsule().fill((filled ? Color(hex: 0x35E08A) : Theme.accentWarm).opacity(0.14))
                  )
                  .overlay(
                    Capsule().strokeBorder(
                      (filled ? Color(hex: 0x35E08A) : Theme.accentWarm).opacity(0.3),
                      lineWidth: 1)
                  )
                  .foregroundColor(filled ? Color(hex: 0x35E08A) : Theme.accentWarm)
              }

              Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          if idx < NetdiskSupport.sites.count - 1 { divider }
        }
      }
      .glassCard(radius: 16)

      Text("从浏览器登录网盘，把请求头里的 Cookie 整条复制进来。夸克与 UC 默认不带 Cookie。")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.8))
        .padding(.leading, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func cookieHint(_ site: NetdiskSite) -> String {
    if site.sendCookie { return "需要 Cookie" }
    if prefs.cookieLength(for: site.key) == 0 { return "可选，默认不带" }
    return prefs.isCookieForced(for: site.key) ? "已填 · 强制带上" : "已填 · 默认不发送"
  }

  // MARK: 关于

  private var aboutSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionLabel("关于")
      HStack {
        Text("版本")
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(Theme.textPrimary)
        Spacer()
        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundColor(Theme.textSecondary)
      }
      .padding(14)
      .glassCard(radius: 16)

      Text("32 线程分块 · 断点续传 · 8 家网盘直链")
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary.opacity(0.8))
        .padding(.leading, 4)
    }
  }
}

extension NetdiskSite: Identifiable {
  var id: String { key }
}

/// 填某个网盘的 Cookie。
struct CookieSheet: View {
  let site: NetdiskSite
  @EnvironmentObject private var prefs: Prefs
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""

  var body: some View {
    ZStack {
      AuroraBackground()

      ScrollView {
        VStack(spacing: 18) {
          // Cookie 输入
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
              Circle()
                .fill(Color(hex: site.color))
                .frame(width: 8, height: 8)
              Text("\(site.name) 的 Cookie")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.textSecondary)
            }

            TextEditor(text: $text)
              .font(.system(size: 12, design: .monospaced))
              .foregroundColor(Theme.textPrimary)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .scrollContentBackgroundHidden()
              .frame(minHeight: 150)
              .padding(10)
              .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(Color.black.opacity(0.28))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
              )

            Text(cookieHelp)
              .font(.system(size: 10))
              .foregroundColor(Theme.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(14)
          .glassCard(radius: 16)

          // 强制 Cookie
          if !site.sendCookie {
            VStack(alignment: .leading, spacing: 8) {
              Toggle(isOn: Binding(
                get: { prefs.isCookieForced(for: site.key) },
                set: { prefs.setCookieForced($0, for: site.key) }
              )) {
                Text("强制带上 Cookie")
                  .font(.system(size: 14, weight: .medium))
                  .foregroundColor(Theme.textPrimary)
              }
              .tint(Theme.accent)

              Text("默认不发。这个网盘如果按账号限速，带上会掉到 ~130 KB/s；但遇到「必须登录才能下」的文件，打开它再试。")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .glassCard(radius: 16)
          }

          // 操作
          VStack(spacing: 10) {
            Button {
              if let clip = UIPasteboard.general.string, !clip.isEmpty {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
              }
            } label: {
              HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard")
                  .font(.system(size: 12, weight: .semibold))
                Text("从剪贴板粘贴")
                  .font(.system(size: 13, weight: .semibold))
              }
              .foregroundColor(Theme.accent)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 13)
              .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                  .fill(Theme.accent.opacity(0.10))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                  .strokeBorder(Theme.accent.opacity(0.24), lineWidth: 1)
              )
            }
            .buttonStyle(.plain)

            if prefs.cookieLength(for: site.key) > 0 {
              Button {
                prefs.setCookie("", for: site.key)
                text = ""
              } label: {
                Text("清除这个网盘的 Cookie")
                  .font(.system(size: 13, weight: .medium))
                  .foregroundColor(Color(hex: 0xFF5E6E))
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 13)
                  .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                      .fill(Color(hex: 0xFF5E6E).opacity(0.09))
                  )
              }
              .buttonStyle(.plain)
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 40)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack {
        Button { dismiss() } label: {
          Text("取消")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.textSecondary)
        }
        .buttonStyle(.plain)

        Spacer()

        Text(site.name)
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundColor(Theme.textPrimary)

        Spacer()

        Button {
          prefs.setCookie(text, for: site.key)
          dismiss()
        } label: {
          Text("保存")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.bgDeep)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.accentGradient))
            .shadow(color: Theme.accent.opacity(0.35), radius: 9, x: 0, y: 3)
        }
        .buttonStyle(.plain)
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
    .onAppear {
      text = prefs.cookie(for: site.key) ?? ""
    }
  }

  private var cookieHelp: String {
    switch site.key {
    case "quark", "uc":
      return "只贴 Cookie 的值就行，形如 __puus=xxx; __pus=yyy。从浏览器 F12 → Network → 随便一个请求 → Request Headers → Cookie 整条复制。注意别把 Cookie: 这四个字符带进来。"
    case "baidu":
      return "关键字段是 BDUSS 和 STOKEN，形如 BDUSS=xxx; STOKEN=yyy。"
    default:
      return "格式与浏览器请求头里一致，多个字段用分号加空格分隔。只存在这台设备上。"
    }
  }
}

// MARK: - iOS 15 兼容

extension View {
  /// iOS 16 才有 `scrollContentBackground(.hidden)`，这里按版本分派。
  @ViewBuilder
  func scrollContentBackgroundHidden() -> some View {
    if #available(iOS 16.0, *) {
      self.scrollContentBackground(.hidden)
    } else {
      self
    }
  }
}
