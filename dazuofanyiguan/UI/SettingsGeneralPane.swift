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
    @Binding var sourceTextFontSize: Double
    @Binding var translatedTextFontSize: Double
    @Binding var miniTextFontSize: Double
    @Binding var draftBaseURL: String
    @Binding var draftModel: String
    @Binding var draftAPIKey: String
    @Binding var draftEndpointModeRawValue: String

    let isSaving: Bool
    let onValidateAndSave: () -> Void
    let onClearKey: () -> Void

    @State private var fontPreview: FontPreview?
    @State private var fontPreviewTask: Task<Void, Never>?

    private struct FontPreview: Equatable {
        let title: String
        let size: Double
    }

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

            SettingsGroup(
                title: "文字大小",
                subtitle: "分别设置原文、译文和 Mini 正文字号。"
            ) {
                SettingsControlRow(
                    icon: "textformat.size",
                    title: "原文",
                    subtitle: "默认 15 pt"
                ) {
                    SettingsFontSizePicker(value: $sourceTextFontSize) {
                        showFontPreview(title: "原文", size: $0)
                    }
                }

                Divider()

                SettingsControlRow(
                    icon: "character.cursor.ibeam",
                    title: "译文",
                    subtitle: "默认 15 pt"
                ) {
                    SettingsFontSizePicker(value: $translatedTextFontSize) {
                        showFontPreview(title: "译文", size: $0)
                    }
                }

                Divider()

                SettingsControlRow(
                    icon: "rectangle.on.rectangle",
                    title: "Mini 窗口",
                    subtitle: "默认 15 pt"
                ) {
                    SettingsFontSizePicker(value: $miniTextFontSize) {
                        showFontPreview(title: "Mini", size: $0)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let fontPreview {
                    FontSizePreview(title: fontPreview.title, size: fontPreview.size)
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: fontPreview)
        }
        .onDisappear {
            fontPreviewTask?.cancel()
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
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("接口配置")
                    .font(.system(size: 13, weight: .semibold))
                Text("填写服务地址、接口类型、模型和密钥。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                SettingsInputField(title: "服务地址", hint: "通常以 /v1 结尾") {
                    TextField("https://api.openai.com/v1", text: $draftBaseURL)
                        .settingsTextFieldChrome()
                }

                HStack(alignment: .top, spacing: 14) {
                    SettingsInputField(title: "接口类型") {
                        Picker("接口类型", selection: $draftEndpointModeRawValue) {
                            ForEach(OpenAIEndpointMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    .frame(width: 240)

                    SettingsInputField(title: "模型") {
                        TextField("例如 gpt-4.1-mini", text: $draftModel)
                            .settingsTextFieldChrome()
                    }
                }

                SettingsInputField(title: "API Key", hint: "仅保存在系统钥匙串") {
                    SecureField("输入 API Key", text: $draftAPIKey)
                        .settingsTextFieldChrome()
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )

            HStack {
                Text("保存时会先验证连接。")
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

    private func showFontPreview(title: String, size: Double) {
        fontPreviewTask?.cancel()
        fontPreview = FontPreview(title: title, size: size)
        fontPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            fontPreview = nil
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

private struct SettingsFontSizePicker: View {
    @Binding var value: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Slider(
                    value: $value,
                    in: AppTextFontSize.allowedRange,
                    step: 1
                )

                HStack {
                    ForEach(AppTextFontSize.tickValues, id: \.self) { size in
                        Text("\(Int(size))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        if size != AppTextFontSize.tickValues.last {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            Text("\(Int(value)) pt")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .frame(width: 280)
        .onChange(of: value) { _, newValue in
            onChange(newValue)
        }
    }
}

private struct FontSizePreview: View {
    let title: String
    let size: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("预览")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(title)文字")
                .font(.system(size: CGFloat(size), weight: .medium))
                .lineLimit(1)
            Text("\(Int(size)) pt")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
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

private struct SettingsInputField<Control: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let control: Control

    init(
        title: String,
        hint: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))

                if let hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsTextFieldChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(scheme == .dark ? 0.72 : 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
            )
    }
}

private extension View {
    func settingsTextFieldChrome() -> some View {
        modifier(SettingsTextFieldChrome())
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
