import SwiftUI

struct HomeToolbarView: View {
    @Binding var sourceLanguageCode: String
    @Binding var targetLanguageCode: String
    @Binding var miniModeEnabled: Bool

    let engineType: TranslationEngineType
    let appearance: AppAppearance
    let statusColor: Color
    let onSwapLanguages: () -> Void
    let onToggleAppearance: () -> Void
    let onOpenConsole: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LanguageSearchPicker(
                title: "源语言",
                allowAuto: true,
                options: LanguagePreset.common,
                selection: $sourceLanguageCode,
                fixedWidth: 205
            )

            Button(action: onSwapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(HomeToolbarIconButtonStyle())
            .help("交换翻译方向")

            LanguageSearchPicker(
                title: "目标语言",
                allowAuto: false,
                options: LanguagePreset.common,
                selection: $targetLanguageCode,
                fixedWidth: 205
            )

            Spacer(minLength: 8)

            engineBadge

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 2)

            Button(action: onToggleAppearance) {
                Image(systemName: appearance == .dark ? "sun.max" : "moon")
            }
            .buttonStyle(HomeToolbarIconButtonStyle())
            .help("切换界面主题")

            Button(action: onOpenConsole) {
                Image(systemName: "terminal")
            }
            .buttonStyle(HomeToolbarIconButtonStyle())
            .help("打开控制台")

            Button {
                miniModeEnabled.toggle()
            } label: {
                Image(
                    systemName: miniModeEnabled
                        ? MiniTranslationIcon.enabled
                        : MiniTranslationIcon.disabled
                )
                .foregroundStyle(miniModeEnabled ? Color.accentColor : .primary)
            }
            .buttonStyle(HomeToolbarIconButtonStyle(isActive: miniModeEnabled))
            .help(miniModeEnabled ? "关闭 Mini 模式" : "开启 Mini 模式")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(HomeToolbarIconButtonStyle())
            .help("打开设置")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var engineBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: engineType.systemImageName)
                .font(.system(size: 13, weight: .semibold))

            Text(engineType.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.70))
        )
        .help("当前翻译服务：\(engineType.title)")
    }
}

private struct HomeToolbarIconButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.12)
                            : Color(nsColor: .windowBackgroundColor).opacity(0.70)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? Color.accentColor.opacity(0.32)
                            : Color.secondary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
