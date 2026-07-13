import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case screenshot
    case help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .shortcuts: return "快捷翻译"
        case .screenshot: return "截图翻译"
        case .help: return "帮助与关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "选择翻译服务并调整应用外观"
        case .shortcuts: return "设置文字翻译的触发方式和 Mini 模式"
        case .screenshot: return "设置截图快捷键、权限和识别行为"
        case .help: return "查看常见问题、项目信息和联系方式"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .screenshot: return "viewfinder"
        case .help: return "questionmark.circle"
        }
    }
}

struct GeneralSettingsPane: View {
    @Binding var engineTypeRawValue: String
    @Binding var appearanceRawValue: String
    @Binding var draftBaseURL: String
    @Binding var draftModel: String
    @Binding var draftAPIKey: String
    @Binding var draftEndpointModeRawValue: String

    let isSaving: Bool
    let onValidateAndSave: () -> Void
    let onClearKey: () -> Void

    private var selectedEngine: TranslationEngineType {
        TranslationEngineType(rawValue: engineTypeRawValue) ?? .apple
    }

    var body: some View {
        VStack(spacing: 20) {
            SettingsGroup(
                title: "翻译服务",
                subtitle: "不同服务的配置互不影响，切换后立即生效。"
            ) {
                HStack(spacing: 10) {
                    ForEach(TranslationEngineType.allCases) { engine in
                        engineButton(engine)
                    }
                }

                engineDetails
                    .padding(.top, 4)
            }

            SettingsGroup(title: "外观") {
                SettingsControlRow(
                    icon: "circle.lefthalf.filled",
                    title: "界面主题",
                    subtitle: "同时应用于主窗口、Mini 气泡和设置窗口。"
                ) {
                    Picker("界面主题", selection: $appearanceRawValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
        }
    }

    private func engineButton(_ engine: TranslationEngineType) -> some View {
        let isSelected = selectedEngine == engine

        return Button {
            engineTypeRawValue = engine.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: engine.systemImageName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            isSelected
                                ? Color.accentColor
                                : Color.secondary.opacity(0.45)
                        )
                }

                Text(engine.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(engineSummary(engine))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var engineDetails: some View {
        switch selectedEngine {
        case .apple:
            SettingsInlineNotice(
                icon: "checkmark.shield",
                title: "系统本地翻译",
                message: "无需 API Key。自动检测会优先使用本地语言识别；首次使用新的语言组合时，macOS 可能要求下载语言模型。",
                tint: .green
            )

        case .google:
            SettingsInlineNotice(
                icon: "network",
                title: "在线翻译",
                message: "无需额外配置，语言识别由 Google 翻译完成。翻译内容需要发送到网络服务。",
                tint: .blue
            )

        case .openAICompatible:
            openAIConfiguration
        }
    }

    private var openAIConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            Text("接口配置")
                .font(.system(size: 13, weight: .semibold))

            SettingsFieldRow(
                title: "Base URL",
                help: "OpenAI 风格接口地址，通常以 /v1 结尾。"
            ) {
                TextField("https://api.openai.com/v1", text: $draftBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow(
                title: "接口类型",
                help: "根据服务商支持的接口格式选择。"
            ) {
                Picker("接口类型", selection: $draftEndpointModeRawValue) {
                    ForEach(OpenAIEndpointMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
            }

            SettingsFieldRow(
                title: "模型",
                help: "填写服务商提供的准确模型名称。"
            ) {
                TextField("例如 gpt-4.1-mini", text: $draftModel)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow(
                title: "API Key",
                help: "仅保存在 macOS 系统钥匙串中。"
            ) {
                SecureField("输入 API Key", text: $draftAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("保存前会发送一条测试请求验证配置。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("清除密钥", action: onClearKey)
                    .disabled(isSaving || draftAPIKey.isEmpty)

                Button(isSaving ? "正在验证…" : "验证并保存", action: onValidateAndSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
    }

    private func engineSummary(_ engine: TranslationEngineType) -> String {
        switch engine {
        case .apple: return "本地 · 默认"
        case .google: return "在线 · 免配置"
        case .openAICompatible: return "在线 · 自定义"
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}

struct SettingsControlRow<Control: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder let control: Control

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 18)
            control
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsFieldRow<Control: View>: View {
    let title: String
    let help: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(help)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)

            control
                .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsInlineNotice: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}
