import SwiftUI

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
          .font(.system(size: 11))
          .foregroundColor(Color.secondary)
      }

      Toggle(isOn: $prefs.useSystemDownloads) {
        VStack(alignment: .leading, spacing: 2) {
          Text("存到系统 Downloads")
          Text(prefs.systemDownloadsAvailable
               ? "/var/mobile/Downloads"
               : "本机不可写，会自动用 App 目录")
            .font(.system(size: 11))
            .foregroundColor(Color.secondary)
        }
      }
      .disabled(!prefs.systemDownloadsAvailable)

      Toggle("下载时保持屏幕常亮", isOn: $prefs.keepAwake)

      HStack {
        Text("当前目录")
        Spacer()
        Text(prefs.saveDirectoryLabel())
          .font(.system(size: 11))
          .foregroundColor(Color.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    } header: {
      Text("下载")
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
              Text(site.sendCookie
                   ? "需要 Cookie"
                   : "不带 Cookie（带了反而被限速）")
                .font(.system(size: 11))
                .foregroundColor(Color.secondary)
            }
            Spacer()
            if site.sendCookie {
              Text(prefs.cookieLength(for: site.key) > 0 ? "已填" : "未填")
                .font(.system(size: 12))
                .foregroundColor(prefs.cookieLength(for: site.key) > 0 ? Color.green : Color.orange)
            }
            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(Color(white: 0.4))
          }
        }
      }
    } header: {
      Text("网盘")
    } footer: {
      Text("从浏览器里登录网盘、复制请求头里的 Cookie 贴进来。夸克与 UC 不用填——它们按账号限速，匿名反而更快。")
    }
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
            .frame(minHeight: 140)
            .font(.system(size: 12, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("\(site.name) 的 Cookie")
        } footer: {
          Text("格式与浏览器请求头里一致，例如 BDUSS=xxx; STOKEN=yyy。只存在这台设备上。")
        }

        if prefs.cookieLength(for: site.key) > 0 {
          Section {
            Button(role: .destructive) {
              prefs.setCookie("", for: site.key)
              text = ""
            } label: {
              Text("清除这个网盘的 Cookie")
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
}
