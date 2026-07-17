import AppKit
import SwiftUI

struct PermissionGuideView: View {
    let needsAccessibility: Bool
    let needsScreenRecording: Bool
    let showsScreenRecordingPermission: Bool

    let onOpenAccessibility: () -> Void
    let onOpenScreenRecording: () -> Void
    let onClose: () -> Void

    @State private var showFallbackExplanation = false
    @State private var showPermissionMigrationExplanation = false

    private var requiredPermissionCount: Int {
        showsScreenRecordingPermission ? 2 : 1
    }

    private var grantedPermissionCount: Int {
        requiredPermissionCount
            - [needsAccessibility, showsScreenRecordingPermission && needsScreenRecording]
                .filter { $0 }
                .count
    }

    private var allPermissionsGranted: Bool {
        !needsAccessibility
            && (!showsScreenRecordingPermission || !needsScreenRecording)
    }

    var body: some View {
        VStack(spacing: 0) {
            guideHeader

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    permissionOverview

                    permissionRow(
                        icon: "accessibility",
                        title: "辅助功能",
                        capability: showsScreenRecordingPermission
                            ? "全局文字快捷键与截图快捷键"
                            : "全局文字快捷键",
                        detail: "允许应用在其他软件中响应 Command + C + C 等全局快捷键。",
                        isGranted: !needsAccessibility,
                        actionTitle: "打开辅助功能设置",
                        action: onOpenAccessibility
                    )

                    if showsScreenRecordingPermission {
                        permissionRow(
                            icon: "rectangle.dashed.badge.record",
                            title: "屏幕录制",
                            capability: "截图翻译与 OCR 取字",
                            detail: "允许应用读取你主动框选的屏幕区域，用于文字识别和翻译。",
                            isGranted: !needsScreenRecording,
                            actionTitle: "打开屏幕录制设置",
                            action: onOpenScreenRecording
                        )
                    }

                    fallbackExplanation
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("权限状态会在你返回应用后自动刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                if allPermissionsGranted {
                    Button("完成", action: onClose)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("稍后处理", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var guideHeader: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(allPermissionsGranted ? "权限已准备完成" : "完善权限以启用全部功能")
                    .font(.system(size: 20, weight: .semibold))

                Text(
                    allPermissionsGranted
                        ? completedPermissionDescription
                        : "仅在使用对应功能时需要这些系统权限。"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var permissionOverview: some View {
        HStack(spacing: 12) {
            Image(
                systemName: allPermissionsGranted
                    ? "checkmark.shield.fill"
                    : "shield.lefthalf.filled"
            )
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(allPermissionsGranted ? Color.green : Color.orange)
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text("已完成 \(grantedPermissionCount) / \(requiredPermissionCount)")
                    .font(.system(size: 13, weight: .semibold))
                Text("应用只会在你主动使用对应功能时读取所需内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    (allPermissionsGranted ? Color.green : Color.orange)
                        .opacity(0.08)
                )
        )
    }

    private var completedPermissionDescription: String {
        showsScreenRecordingPermission
            ? "全局快捷翻译和截图翻译均可正常使用。"
            : "全局快捷翻译已可正常使用。"
    }

    private var fallbackExplanation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showFallbackExplanation.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showFallbackExplanation ? 90 : 0))

                    Text("暂不授权辅助功能还能使用吗？")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFallbackExplanation {
                Text("可以。在设置中选择“剪贴板监听”后，连续按两次 Command + C 会读取剪贴板并翻译。无法复制的网页或控件不会产生可翻译内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.leading, 19)
            }

            Divider()
                .padding(.vertical, 12)

            Button {
                showPermissionMigrationExplanation.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(
                            .degrees(showPermissionMigrationExplanation ? 90 : 0)
                        )

                    Text("系统设置已开启，为什么仍提示未授权？")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showPermissionMigrationExplanation {
                Text("1.2.1 及更早版本使用临时签名，首次升级到正式签名版本时，macOS 可能仍保留无法匹配的旧权限记录。请在系统设置中删除旧条目，再把上方应用图标拖入权限列表并开启；完成这一次迁移后，后续更新会保持同一权限身份。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.leading, 19)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
    }

    private func permissionRow(
        icon: String,
        title: String,
        capability: String,
        detail: String,
        isGranted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))

                    Label(
                        isGranted ? "已授权" : "未授权",
                        systemImage: isGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                }

                Text(capability)
                    .font(.system(size: 12, weight: .medium))

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isGranted {
                    permissionDragGuide(
                        actionTitle: actionTitle,
                        action: action
                    )
                    .padding(.top, 7)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func permissionDragGuide(
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            draggableApplicationIcon

            VStack(alignment: .leading, spacing: 3) {
                Text("拖入权限列表")
                    .font(.system(size: 11, weight: .semibold))
                Text("先打开对应系统设置，再把左侧图标拖入应用列表并开启开关。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var draggableApplicationIcon: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)

                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Color.orange))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
            }

            Text("拖动")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 54)
        .contentShape(Rectangle())
        .onDrag {
            PermissionGuideDragItemProvider.make()
        }
        .help("将大佐翻译官拖到系统设置的权限列表")
    }
}

enum PermissionGuideDragItemProvider {
    static func make(applicationURL: URL = Bundle.main.bundleURL) -> NSItemProvider {
        NSItemProvider(object: applicationURL as NSURL)
    }
}
