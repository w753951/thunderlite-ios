import SwiftUI
import UIKit

struct SettingsView: View {
  @EnvironmentObject private var prefs: Prefs
  @Environment(\.dismiss) private var dismiss

  @State private var editingSite: NetdiskSite?

  var body: some View {
    NavigationView {
      Form {
        download
        netdisk
        about
      }
      .navigationTitle("设置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("完成") { dismiss() }
        }
      }
      .sheet(item: $editingSite) { site in
        CookieSheet(site: site).environmentObject(prefs)
      }
    }
    .navigationViewStyle(.stack)
  }

  // MARK: - 下载

  private var download: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("线程数")
          Spacer()
          Text("\(prefs.threads)")
            .foregroundColor(Color.secondary)
            .monospacedDigit()
        }
        Slider(
          value: Binding(
            get: { Double(prefs.threads) },
            set: { prefs.threads = Int($0.rounded()) }
          ),
          in: 1...32,
          step: 1
        )
        Text("网盘会自动收窄并发：夸克 32、百度 8、阿里 4 —— 开太高会被 CDN 限流。")
          .font(.footnote)
          .foregroundColor(Color.secondary)
      }

      Toggle(isOn: $prefs.useSystemDownloads) {
        VStack(alignment: .leading, spacing: 2) {
          Text("存到系统 Downloads")
          Text(prefs.systemDownloadsAvailable
               ? "/var/mobile/Downloads"
               : "本机不可写，会自动用 App 目录")
            .font(.footnote)
            .foregroundColor(Color.secondary)
        }
      }
      .disabled(!prefs.systemDownloadsAvailable)

      Toggle("下载时保持屏幕常亮", isOn: $prefs.keepAwake)

      Button {
        DirOpener.open(prefs.saveDirectory())
      } label: {
        HStack {
          Text("当前目录")
            .foregroundColor(Color.primary)
          Spacer()
          Text(prefs.saveDirectoryLabel())
            .font(.footnote)
            .foregroundColor(Color.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "arrow.up.forward.app")
            .font(.footnote.weight(.semibold))
            .foregroundColor(Color.accentColor)
        }
      }
    } header: {
      Text("下载")
    } footer: {
      Text("点「当前目录」会在 Filza 里打开这个文件夹；没装 Filza 就退回「文件」App。")
    }
  }

  // MARK: - 网盘

  private var netdisk: some View {
    Section {
      ForEach(NetdiskSupport.sites, id: \.key) { site in
        Button {
          editingSite = site
        } label: {
          HStack(spacing: 10) {
            Circle()
              .fill(Color(hex: site.color))
              .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
              Text(site.name)
                .foregroundColor(Color.primary)
              Text(cookieHint(site))
                .font(.footnote)
                .foregroundColor(Color.secondary)
            }
            Spacer()
            if site.sendCookie || prefs.cookieLength(for: site.key) > 0 {
              Text(prefs.cookieLength(for: site.key) > 0 ? "已填" : "未填")
                .font(.footnote)
                .foregroundColor(prefs.cookieLength(for: site.key) > 0 ? Color.green : Color.orange)
            }
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundColor(Color(white: 0.4))
          }
        }
      }
    } header: {
      Text("网盘")
    } footer: {
      Text("从浏览器里登录网盘，把请求头里的 Cookie 整条复制进来。夸克与 UC 默认不带 Cookie（带了可能被按账号限速），但需要登录才能下的文件可以进详情页打开「强制带上 Cookie」。")
    }
  }

  /// 每个站点一行状态说明。夸克/UC 要区分「没填」和「填了但在强制」。
  private func cookieHint(_ site: NetdiskSite) -> String {
    if site.sendCookie { return "需要 Cookie" }
    if prefs.cookieLength(for: site.key) == 0 { return "可选，默认不带（带了反而可能被限速）" }
    return prefs.isCookieForced(for: site.key)
      ? "已填 · 正在强制带上"
      : "已填 · 默认不发送"
  }

  // MARK: - 关于

  private var about: some View {
    Section {
      HStack {
        Text("版本")
        Spacer()
        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
          .foregroundColor(Color.secondary)
      }
    } header: {
      Text("关于")
    } footer: {
      Text("最多 32 线程分块 · 断点续传 · 8 家网盘直链")
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
    NavigationView {
      Form {
        Section {
          TextEditor(text: $text)
            .frame(minHeight: 160)
            .font(.system(.footnote, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("\(site.name) 的 Cookie")
        } footer: {
          Text(cookieHelp)
        }

        if !site.sendCookie {
          Section {
            Toggle("强制带上 Cookie", isOn: Binding(
              get: { prefs.isCookieForced(for: site.key) },
              set: { prefs.setCookieForced($0, for: site.key) }
            ))
          } footer: {
            Text("默认不发。这个网盘如果按账号限速，带上会掉到 ~130 KB/s；但遇到「必须登录才能下」的文件，打开它再试。")
          }
        }

        if prefs.cookieLength(for: site.key) > 0 {
          Section {
            Button {
              if let clip = UIPasteboard.general.string, !clip.isEmpty {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
              }
            } label: {
              Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive) {
              prefs.setCookie("", for: site.key)
              text = ""
            } label: {
              Text("清除这个网盘的 Cookie")
            }
          }
        } else {
          Section {
            Button {
              if let clip = UIPasteboard.general.string, !clip.isEmpty {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
              }
            } label: {
              Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
            }
          }
        }
      }
      .navigationTitle(site.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("保存") {
            prefs.setCookie(text, for: site.key)
            dismiss()
          }
        }
      }
      .onAppear {
        text = prefs.cookie(for: site.key) ?? ""
      }
    }
    .navigationViewStyle(.stack)
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
