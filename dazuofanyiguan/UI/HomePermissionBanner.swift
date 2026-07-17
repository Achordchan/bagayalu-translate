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
        HomeFeatureBanner(
            icon: "lock.open.trianglebadge.exclamationmark",
            tint: .orange,
            title: "完善系统权限",
            message: summary
        ) {
            Button("稍后", action: onIgnore)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("查看权限", action: onOpenGuide)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        }
    }
}

struct GlobalHotkeyRecommendationBanner: View {
    let isRetry: Bool
    let onEnable: () -> Void
    let onIgnore: () -> Void
    let onNeverRemind: () -> Void

    var body: some View {
        HomeFeatureBanner(
            icon: "command.circle",
            tint: .blue,
            title: isRetry ? "全局快捷键未成功启动" : "使用全局快捷键模式",
            message: isRetry
                ? "当前已回退到剪贴板监听，可重新启用。"
                : "触发更准确，也不会持续监听剪贴板变化。"
        ) {
            Button("永不提醒", action: onNeverRemind)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .controlSize(.small)

            Button("忽略", action: onIgnore)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("启用", action: onEnable)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

private struct HomeFeatureBanner<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(tint.opacity(0.26), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 7)
        .frame(maxWidth: 680)
    }
}
