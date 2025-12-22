import SwiftUI

struct PermissionGuideView: View {
    let needsAccessibility: Bool
    let needsScreenRecording: Bool

    let onOpenAccessibility: () -> Void
    let onOpenScreenRecording: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            welcomeHeader

            featureCard

            permissionCard

            Text("提示：不授权“辅助功能”也可以使用——在设置中启用“监听剪贴板”模式，双击 Cmd+C 后应用会读取剪贴板并翻译。但遇到无法复制的网页/内容，剪贴板拿不到文字，就无法触发翻译。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("关闭") {
                    onClose()
                }
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private var welcomeHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("欢迎使用 大佐翻译官 v1")
                    .font(.system(size: 20, weight: .bold))
                Text("更快、更顺手的翻译小工具")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.35)

            HStack(spacing: 14) {
                Text("作者：Achord")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let url = URL(string: "mailto:achordchan@gmail.com") {
                    Link("achordchan@gmail.com", destination: url)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("achordchan@gmail.com")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("软件特色")
                .font(.system(size: 13, weight: .bold))

            featureRow(title: "Cmd+C+C 快捷翻译", desc: "推荐授权辅助功能：不依赖剪贴板，更稳定。")
            featureRow(title: "监听剪贴板翻译", desc: "不授权也能用，但只能翻译“能复制”的文字。")
            featureRow(title: "截图翻译", desc: "需要屏幕录制权限；识别不准时建议优先复制文字翻译。")
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    private func featureRow(title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(desc)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议授权")
                .font(.system(size: 13, weight: .bold))

            if needsAccessibility {
                permissionRow(
                    title: "辅助功能（用于全局快捷键 Cmd+C+C / Cmd+X+X）",
                    desc: "开启后，应用才能在任何应用里直接响应快捷键（不依赖剪贴板监听）。",
                    actionTitle: "打开辅助功能设置",
                    action: onOpenAccessibility
                )
            }

            if needsScreenRecording {
                permissionRow(
                    title: "屏幕录制（用于截图取字）",
                    desc: "开启后，应用才能读取屏幕像素并进行 OCR。",
                    actionTitle: "打开屏幕录制设置",
                    action: onOpenScreenRecording
                )
            }

            if !needsAccessibility && !needsScreenRecording {
                Text("权限已齐全，可以开始使用快捷键")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.9))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        desc: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Text(desc)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Button(actionTitle) {
                action()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
