import SwiftUI

struct HomePermissionBanner: View {
    let needsAccessibility: Bool
    let needsScreenRecording: Bool
    let onOpenGuide: () -> Void
    let onIgnore: () -> Void

    private var summary: String {
        if needsAccessibility && needsScreenRecording {
            return "全局快捷键和截图翻译尚未完整启用"
        }
        if needsAccessibility {
            return "全局快捷键尚未启用，当前仍可使用剪贴板监听"
        }
        return "截图翻译尚未启用"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("完善系统权限")
                    .font(.system(size: 12, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button("稍后", action: onIgnore)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("查看权限", action: onOpenGuide)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.26), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 7)
        .frame(maxWidth: 680)
    }
}
