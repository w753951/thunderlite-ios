import SwiftUI

// MARK: - 清理缓存

struct CacheCleanerView: View {
  @StateObject private var cleaner = CacheCleaner.shared
  @Environment(\.dismiss) private var dismiss

  @State private var showConfirm = false
  @State private var clearedText: String?
  @State private var spinning = false

  var body: some View {
    ZStack {
      AuroraBackground()

      ScrollView {
        VStack(spacing: 20) {
          totalCard
          itemList
          tipText
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 40)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { topBar }
    .onAppear { if cleaner.items.isEmpty { cleaner.scan() } }
    .alert("清理缓存", isPresented: $showConfirm) {
      Button("取消", role: .cancel) {}
      Button("清理", role: .destructive) {
        Task { await doClear() }
      }
    } message: {
      Text("将清理 \(CacheCleaner.sizeText(cleaner.totalBytes)) 的缓存。\n\nCookie、登录状态、下载好的文件和任务列表都会保留。")
    }
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

      Text("清理缓存")
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundColor(Theme.textPrimary)

      Spacer()

      Button {
        spinning = true
        cleaner.scan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { spinning = false }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(Theme.textSecondary)
          .rotationEffect(.degrees(spinning ? 360 : 0))
          .animation(.easeInOut(duration: 0.6), value: spinning)
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

  // MARK: 总量卡片

  private var totalCard: some View {
    VStack(spacing: 14) {
      // 环形进度示意（按各分项占比）
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.06), lineWidth: 8)
          .frame(width: 96, height: 96)

        Circle()
          .trim(from: 0, to: cleaner.totalBytes > 0 ? 1 : 0)
          .stroke(
            Theme.accentGradient,
            style: StrokeStyle(lineWidth: 8, lineCap: .round)
          )
          .frame(width: 96, height: 96)
          .rotationEffect(.degrees(-90))

        VStack(spacing: 1) {
          Text(CacheCleaner.sizeText(cleaner.totalBytes))
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(Theme.textPrimary)
          Text("可清理")
            .font(.system(size: 9))
            .foregroundColor(Theme.textTertiary)
        }
      }
      .padding(.top, 4)

      if let clearedText {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
          Text("已释放 \(clearedText)")
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(Color(hex: 0x35E08A))
      }

      Button {
        showConfirm = true
      } label: {
        HStack(spacing: 8) {
          if cleaner.clearing {
            ProgressView().tint(Theme.bgDeep).scaleEffect(0.75)
          } else {
            Image(systemName: "trash.fill")
              .font(.system(size: 13, weight: .bold))
          }
          Text(cleaner.clearing ? "正在清理…" : "一键清理")
            .font(.system(size: 15, weight: .semibold))
        }
        .foregroundColor(Theme.bgDeep)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.accentGradient)
        )
        .shadow(color: Theme.accent.opacity(0.35), radius: 12, x: 0, y: 4)
      }
      .buttonStyle(.plain)
      .disabled(cleaner.clearing || cleaner.totalBytes == 0)
      .opacity(cleaner.totalBytes == 0 ? 0.45 : 1)
    }
    .padding(18)
    .glassCard(radius: 18)
  }

  // MARK: 分项列表

  private var itemList: some View {
    VStack(spacing: 0) {
      if cleaner.scanning && cleaner.items.isEmpty {
        HStack(spacing: 9) {
          ProgressView().tint(Theme.accent).scaleEffect(0.75)
          Text("正在统计缓存…")
            .font(.system(size: 12))
            .foregroundColor(Theme.textTertiary)
          Spacer()
        }
        .padding(16)
      } else {
        ForEach(Array(cleaner.items.enumerated()), id: \.element.id) { idx, item in
          HStack(spacing: 12) {
            Image(systemName: iconFor(item.name))
              .font(.system(size: 14, weight: .semibold))
              .foregroundColor(item.bytes > 0 ? Theme.accent : Theme.textTertiary)
              .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
              Text(item.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textPrimary)
              Text(item.detail)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
            }

            Spacer(minLength: 6)

            Text(CacheCleaner.sizeText(item.bytes))
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .foregroundColor(item.bytes > 0 ? Theme.textSecondary : Theme.textTertiary)

            Button {
              Task { _ = await cleaner.clear(item) }
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(Theme.textTertiary.opacity(item.bytes > 0 ? 0.65 : 0.2))
            }
            .buttonStyle(.plain)
            .disabled(item.bytes == 0)
          }
          .padding(.horizontal, 15)
          .padding(.vertical, 12)

          if idx < cleaner.items.count - 1 { divider }
        }
      }
    }
    .glassCard(radius: 16)
  }

  private var tipText: some View {
    Text("清理缓存不会影响已下载的文件、任务列表和网盘登录状态。浏览器 Cookie 请在「Cookie 管理」里单独处理。")
      .font(.system(size: 10))
      .foregroundColor(Theme.textTertiary.opacity(0.85))
      .padding(.leading, 4)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.white.opacity(0.055))
      .frame(height: 1)
      .padding(.leading, 51)
  }

  private func iconFor(_ name: String) -> String {
    switch name {
    case "浏览器缓存": return "safari"
    case "网络请求缓存": return "arrow.left.arrow.right"
    case "临时文件": return "folder.badge.gearshape"
    case "缩略图缓存": return "photo.stack"
    case "运行日志": return "doc.text"
    default: return "archivebox"
    }
  }

  // MARK: 动作

  private func doClear() async {
    let freed = await cleaner.clearAll()
    clearedText = CacheCleaner.sizeText(freed)
    // 5 秒后淡出提示
    try? await Task.sleep(nanoseconds: 5_000_000_000)
    clearedText = nil
  }
}
