import SwiftUI

enum TextShortcutMode: String, CaseIterable, Identifiable {
    case global
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "全局快捷键"
        case .clipboard: return "剪贴板监听"
        }
    }
}

struct ShortcutSettingsPane: View {
    @Binding var textShortcutEnabled: Bool
    @Binding var shortcutMode: TextShortcutMode
    @Binding var miniModeEnabled: Bool
    @Binding var doubleCopyWindowMs: Int

    let hasAccessibilityPermission: Bool
    let onOpenPermissionGuide: () -> Void

    @State private var showTimingSettings = false

    var body: some View {
        VStack(spacing: 20) {
            SettingsGroup(
                title: "文字快捷翻译",
                subtitle: "连续按两次 Command + C，翻译当前选中的文字。"
            ) {
                SettingsControlRow(
                    icon: "command",
                    title: "启用快捷翻译",
                    subtitle: textShortcutEnabled ? "当前可通过 Command + C + C 触发。" : "关闭后不会监听文字快捷键。"
                ) {
                    Toggle("启用快捷翻译", isOn: $textShortcutEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if textShortcutEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("触发方式")
                            .font(.system(size: 12, weight: .medium))

                        Picker("触发方式", selection: $shortcutMode) {
                            ForEach(TextShortcutMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        shortcutModeDescription
                    }

                    Divider()

                    SettingsControlRow(
                        icon: "rectangle.on.rectangle",
                        title: "Mini 模式",
                        subtitle: "翻译时不弹出主窗口，只在鼠标附近显示结果气泡。"
                    ) {
                        Toggle("Mini 模式", isOn: $miniModeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    DisclosureGroup("触发时间窗口", isExpanded: $showTimingSettings) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("两次按键最大间隔")
                                    .font(.system(size: 12))
                                Spacer()
                                Stepper(
                                    "\(doubleCopyWindowMs) ms",
                                    value: $doubleCopyWindowMs,
                                    in: 250...1200,
                                    step: 50
                                )
                                .frame(width: 160)
                            }

                            Text("数值越小越不容易误触；默认 550 ms 适合大多数用户。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }

            if textShortcutEnabled, miniModeEnabled {
                SettingsInlineNotice(
                    icon: "info.circle",
                    title: "Mini 模式回退规则",
                    message: "需要下载 Apple 语言模型或补充 OpenAI 配置时，应用会打开主窗口继续处理；普通翻译错误只显示在气泡中。",
                    tint: .blue
                )
            }
        }
    }

    @ViewBuilder
    private var shortcutModeDescription: some View {
        switch shortcutMode {
        case .global:
            if hasAccessibilityPermission {
                SettingsInlineNotice(
                    icon: "checkmark.circle",
                    title: "辅助功能已授权",
                    message: "直接监听 Command + C，触发判定更准确；翻译内容仍来自目标应用复制到剪贴板的文字。",
                    tint: .green
                )
            } else {
                permissionNotice(
                    message: "全局快捷键需要辅助功能权限。未授权时会自动使用剪贴板监听模式。"
                )
            }

        case .clipboard:
            SettingsInlineNotice(
                icon: "doc.on.clipboard",
                title: "无需辅助功能权限",
                message: "触发时读取剪贴板内容。无法复制的网页或控件不会产生可翻译文字。",
                tint: .orange
            )
        }
    }

    private func permissionNotice(message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsInlineNotice(
                icon: "exclamationmark.triangle",
                title: "缺少辅助功能权限",
                message: message,
                tint: .orange
            )

            Button("去授权", action: onOpenPermissionGuide)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct ScreenshotSettingsPane: View {
    @Binding var enabled: Bool
    @Binding var hotkeyKeyCode: Int
    @Binding var freezeBackgroundEnabled: Bool

    let hasAccessibilityPermission: Bool
    let hasScreenRecordingPermission: Bool
    let onOpenPermissionGuide: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            SettingsGroup(
                title: "截图快捷翻译",
                subtitle: "框选屏幕区域后进行 OCR 识别和翻译。"
            ) {
                SettingsControlRow(
                    icon: "viewfinder",
                    title: "启用截图翻译",
                    subtitle: enabled ? "截图快捷键已启用。" : "关闭后不会监听截图快捷键。"
                ) {
                    Toggle("启用截图翻译", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if enabled {
                    Divider()

                    SettingsControlRow(
                        icon: "keyboard",
                        title: "截图快捷键",
                        subtitle: "连续按两次对应组合键。"
                    ) {
                        Picker("截图快捷键", selection: $hotkeyKeyCode) {
                            Text("Command + X + X").tag(7)
                            Text("Command + S + S").tag(1)
                            Text("Command + D + D").tag(2)
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    SettingsControlRow(
                        icon: "photo.on.rectangle.angled",
                        title: "冻结截图背景",
                        subtitle: "选区时固定当前屏幕画面，更接近系统截图体验。"
                    ) {
                        Toggle("冻结截图背景", isOn: $freezeBackgroundEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            SettingsGroup(title: "系统权限") {
                permissionRow(
                    icon: "accessibility",
                    title: "辅助功能",
                    message: "用于监听全局截图快捷键",
                    isGranted: hasAccessibilityPermission
                )

                Divider()

                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "屏幕录制",
                    message: "用于读取选区像素并执行 OCR",
                    isGranted: hasScreenRecordingPermission
                )

                if !hasAccessibilityPermission || !hasScreenRecordingPermission {
                    HStack {
                        Text("权限变更后，返回应用即可刷新状态。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开权限引导", action: onOpenPermissionGuide)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }

            SettingsInlineNotice(
                icon: "text.viewfinder",
                title: "识别效果说明",
                message: "OCR 准确率会受到字体、清晰度和背景影响。能直接复制文字时，优先使用文字快捷翻译。",
                tint: .blue
            )
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        message: String,
        isGranted: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(
                isGranted ? "已授权" : "未授权",
                systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
    }
}
