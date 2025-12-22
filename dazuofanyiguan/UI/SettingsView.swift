import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: LogStore
    @EnvironmentObject private var hotkeyMonitor: GlobalHotkeyMonitor

    @StateObject private var windowBehavior = SettingsWindowBehavior()

    @State private var draftBaseURL: String = ""
    @State private var draftModel: String = ""
    @State private var draftAPIKey: String = ""
    @State private var draftEndpointModeRawValue: String = OpenAIEndpointMode.chatCompletions.rawValue
    @State private var loaded: Bool = false

    @State private var isSaving: Bool = false
    @State private var showAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var openPermissionGuideAfterAlert: Bool = false

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case translation
        case hotkeys
        case faq
        case advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .translation: return "翻译设置"
            case .hotkeys: return "快捷键设置"
            case .faq: return "常见问题"
            case .advanced: return "高级设置"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .translation
    @State private var expandedFAQ: Set<Int> = [0]

    var body: some View {
        VStack(spacing: 16) {
            header

            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)

            Group {
                switch selectedTab {
                case .translation:
                    Form {
                        Section("翻译服务") {
                            LabeledContent("当前引擎") {
                                Picker("", selection: $settings.engineTypeRawValue) {
                                    ForEach(TranslationEngineType.allCases) { item in
                                        Text(item.title).tag(item.rawValue)
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        Section("OpenAI 通用接口") {
                            LabeledContent("Base URL") {
                                HStack(spacing: 8) {
                                    TextField("", text: $draftBaseURL)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                    InfoTip(text: "OpenAI 风格接口的 Base URL。通常以 /v1 结尾。")
                                }
                            }

                            LabeledContent("接口类型") {
                                Picker("", selection: $draftEndpointModeRawValue) {
                                    ForEach(OpenAIEndpointMode.allCases) { item in
                                        Text(item.title).tag(item.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 320, alignment: .leading)
                            }

                            LabeledContent("Model") {
                                HStack(spacing: 8) {
                                    TextField("", text: $draftModel)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                    InfoTip(text: "模型名称。不同服务商的命名不同。")
                                }
                            }

                            LabeledContent("API Key") {
                                HStack(spacing: 8) {
                                    SecureField("", text: $draftAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                    InfoTip(text: "仅保存到系统 Keychain")
                                }
                            }

                            HStack {
                                Spacer()

                                Button(isSaving ? "正在验证…" : "验证并保存") {
                                    Task { @MainActor in
                                        await validateAndSave()
                                    }
                                }
                                .disabled(isSaving)

                                Button("清除") {
                                    Task { @MainActor in
                                        await clearKey()
                                    }
                                }
                                .disabled(isSaving)
                            }
                        }
                    }
                    .formStyle(.grouped)

                case .hotkeys:
                    Form {
                        Section("快捷唤起") {
                            Toggle("启用 Command + C + C（监听剪贴，会占用剪贴板）", isOn: $settings.doubleCopyEnabled)
                                .disabled(settings.globalHotkeyEnabled)

                            Toggle("启用全局快捷键 Command + C + C", isOn: $settings.globalHotkeyEnabled)

                            if settings.globalHotkeyEnabled {
                                if hotkeyMonitor.isTrusted {
                                    Text("全局快捷键已授权，可在任何应用中使用。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("要启用全局快捷键，需要在系统设置中授予“辅助功能”权限。")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)

                                        Text("如果你不授权，也可以使用“监听剪贴板”模式；但遇到无法复制的网页/内容，就无法触发翻译。")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)

                                        HStack(spacing: 10) {
                                            Button("辅助功能授权") {
                                                hotkeyMonitor.requestAccessibilityPermission()
                                                GlobalHotkeyMonitor.openAccessibilitySettings()
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            LabeledContent("时间窗口（双击间隔）") {
                                Stepper(value: $settings.doubleCopyWindowMs, in: 250...1200, step: 50) {
                                    Text("\(settings.doubleCopyWindowMs) ms")
                                        .frame(width: 100, alignment: .trailing)
                                }
                            }

                            Text("两次 Command + C 的间隔小于这个数值时，才会触发唤起翻译。数值越小越不容易误触。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Section("截图翻译") {
                            Text("截图翻译会先截取选区图片，再尝试 OCR 识别文字。免费 OCR 能力有限，建议优先复制文字翻译。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Toggle("启用截图翻译快捷键", isOn: $settings.screenshotHotkeyEnabled)

                            LabeledContent("截图快捷键") {
                                Picker("", selection: $settings.screenshotHotkeyKeyCode) {
                                    Text("Cmd + X + X").tag(7)
                                    Text("Cmd + S + S").tag(1)
                                    Text("Cmd + D + D").tag(2)
                                }
                                .labelsHidden()
                                .frame(width: 200, alignment: .leading)
                            }

                            Toggle("截图翻译时冻结背景（更接近系统截图效果）", isOn: $settings.screenshotFreezeBackgroundEnabled)
                        }
                    }
                    .formStyle(.grouped)

                case .faq:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            faqItem(index: 0, q: "不授权辅助功能还能用吗？", a: "可以。你可以开启“监听剪贴板”模式：双击 Cmd+C 后，本应用读取剪贴板内容进行翻译。但遇到无法复制的网页/内容，就无法触发翻译。建议授权“辅助功能”，使用全局快捷键体验更稳定。")
                            faqItem(index: 1, q: "为什么我双击 Cmd+C 没反应？", a: "请检查：1) 是否开启了对应模式（全局快捷键/监听剪贴板）；2) 双击间隔是否过小；3) 全局快捷键模式是否已授权“辅助功能”。")
                            faqItem(index: 2, q: "截图翻译识别不准怎么办？", a: "截图翻译使用本地免费 OCR，受字体/清晰度/背景影响较大。建议优先复制文字翻译；或者放大页面、提高对比度后再截图。")
                            faqItem(index: 3, q: "为什么需要屏幕录制权限？", a: "截图翻译需要读取屏幕像素进行截图和 OCR。不开启屏幕录制将无法使用截图翻译。")
                        }
                        .padding(14)
                    }

                case .advanced:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("高级设置")
                            .font(.system(size: 14, weight: .bold))
                        Text("敬请期待")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 620)
        .background(
            WindowAccessor { window in
                guard let window else { return }
                if window.title != "设置" {
                    window.title = "设置"
                }
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false

                windowBehavior.attach(window)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if loaded { return }
            loaded = true
            draftBaseURL = settings.openAIBaseURL
            draftModel = settings.openAIModel
            draftEndpointModeRawValue = settings.openAIEndpointModeRawValue
            do {
                draftAPIKey = (try KeychainStore.getString(for: "openAIAPIKey")) ?? ""
            } catch {
                log.error("读取 Keychain 失败：\(error.localizedDescription)")
            }

            if settings.globalHotkeyEnabled, !hotkeyMonitor.isTrusted {
                settings.globalHotkeyEnabled = false
                settings.doubleCopyEnabled = true
            }

            let sKey = "didAutoEnableScreenshotHotkeyV1"
            if ScreenCapturePermission.hasPermission(), !UserDefaults.standard.bool(forKey: sKey) {
                settings.screenshotHotkeyEnabled = true
                UserDefaults.standard.set(true, forKey: sKey)
            }
        }
        .onChange(of: settings.globalHotkeyEnabled) { _, enabled in
            if enabled {
                if hotkeyMonitor.isTrusted {
                    settings.doubleCopyEnabled = false
                } else {
                    settings.globalHotkeyEnabled = false
                    settings.doubleCopyEnabled = true
                    alertTitle = "需要辅助功能权限"
                    alertMessage = "你尚未授权“辅助功能”。已为你自动切换到“监听剪贴板”模式：双击 Cmd+C 触发翻译。建议授权后使用全局快捷键，更稳定。"
                    showAlert = true
                    openPermissionGuideAfterAlert = true
                }
            }
        }
        .onChange(of: settings.screenshotHotkeyEnabled) { _, enabled in
            if enabled {
                let needsAccessibility = !AXIsProcessTrusted()
                let needsScreenRecording = !ScreenCapturePermission.hasPermission()
                if needsAccessibility || needsScreenRecording {
                    settings.screenshotHotkeyEnabled = false
                    alertTitle = "需要权限才能启用"
                    if needsAccessibility && needsScreenRecording {
                        alertMessage = "截图翻译快捷键通过全局快捷键监听触发，需要“辅助功能”+“屏幕录制”权限。请授权后再开启。"
                    } else if needsAccessibility {
                        alertMessage = "截图翻译快捷键通过全局快捷键监听触发，需要“辅助功能”权限。请授权后再开启。"
                    } else {
                        alertMessage = "截图翻译需要“屏幕录制”权限。请授权后再开启。"
                    }
                    showAlert = true
                    openPermissionGuideAfterAlert = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if settings.globalHotkeyEnabled, hotkeyMonitor.isTrusted, !hotkeyMonitor.isRunning {
                hotkeyMonitor.start(windowMs: settings.doubleCopyWindowMs, doubleCutKeyCode: settings.screenshotHotkeyKeyCode)
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好的") {
                if openPermissionGuideAfterAlert {
                    openPermissionGuideAfterAlert = false
                    NotificationCenter.default.post(name: .dazuofanyiguanOpenPermissionGuide, object: nil)
                }
            }
        } message: {
            Text(alertMessage)
        }
    }

    @MainActor
    private final class SettingsWindowBehavior: NSObject, ObservableObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private var didCenterThisShow: Bool = false

        func attach(_ window: NSWindow) {
            if self.window !== window {
                self.window = window
                window.isRestorable = false
                window.delegate = self
                didCenterThisShow = false
            }
        }

        func windowDidBecomeKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if !didCenterThisShow {
                didCenterThisShow = true
                centerWindowRelativeToMain(window)
            }
        }

        func windowWillClose(_ notification: Notification) {
            didCenterThisShow = false
        }

        private func centerWindowRelativeToMain(_ window: NSWindow) {
            let mainWindow = NSApp.windows.first(where: { $0.identifier == AppWindowController.mainWindowIdentifier })

            guard let main = mainWindow ?? NSApp.mainWindow ?? NSApp.keyWindow else {
                window.center()
                return
            }

            let mainFrame = main.frame
            var newOrigin = CGPoint(
                x: mainFrame.midX - window.frame.width / 2,
                y: mainFrame.midY - window.frame.height / 2
            )

            // 尽量限制在主窗口所在屏幕的可见区域内。
            let screenFrame = main.screen?.visibleFrame ?? window.screen?.visibleFrame
            if let screenFrame {
                newOrigin.x = min(max(newOrigin.x, screenFrame.minX), screenFrame.maxX - window.frame.width)
                newOrigin.y = min(max(newOrigin.y, screenFrame.minY), screenFrame.maxY - window.frame.height)
            }

            window.setFrameOrigin(newOrigin)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            

            VStack(spacing: 10) {
                AsyncImage(
                    url: URL(string: "https://avatars.githubusercontent.com/u/179492542?s=400&u=a50df16bf8ecd12a8f7e3c8761f7afa4c366836e&v=4")
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 4)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 6)
                .padding(.top, 2)

                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                        Text("Achord")
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "phone.fill")
                            .foregroundStyle(.secondary)
                        Text("13160235855")
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.secondary)
                        if let url = URL(string: "mailto:achordchan@gmail.com") {
                            Link("achordchan@gmail.com", destination: url)
                                .foregroundStyle(.blue)
                        } else {
                            Text("achordchan@gmail.com")
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    if let url = URL(string: "https://github.com/Achordchan/bagayalu-translate") {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.left.slash.chevron.right")
                                Text("项目地址")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .dsPill()
                        }
                        .buttonStyle(.plain)
                    }

                    if let url = URL(string: "https://github.com/Achordchan/bagayalu-translate/blob/main/PRIVACY.md") {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised.fill")
                                Text("隐私条款")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .dsPill()
                        }
                        .buttonStyle(.plain)
                    }

                    if let url = URL(string: "https://github.com/Achordchan/bagayalu-translate/blob/main/LICENSE") {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text.fill")
                                Text("开源协议")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .dsPill()
                        }
                        .buttonStyle(.plain)
                    }

                    if let url = URL(string: "https://ifdian.net/a/achord") {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "heart.fill")
                                Text("赞助我")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .dsPill()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .dsCard()
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func faqItem(index: Int, q: String, a: String) -> some View {
        let isExpanded = expandedFAQ.contains(index)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded {
                    expandedFAQ.remove(index)
                } else {
                    expandedFAQ.insert(index)
                }
            } label: {
                HStack(spacing: 10) {
                    Text(q)
                        .font(.system(size: 13, weight: isExpanded ? .bold : .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(a)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .dsCard()
    }

    @MainActor
    private func validateAndSave() async {
        isSaving = true
        defer { isSaving = false }

        let baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointMode = OpenAIEndpointMode(rawValue: draftEndpointModeRawValue) ?? .chatCompletions

        if baseURL.isEmpty || model.isEmpty || key.isEmpty {
            alertTitle = "无法保存"
            alertMessage = "Base URL / Model / API Key 不能为空。"
            showAlert = true
            return
        }

        do {
            let engine = OpenAICompatibleEngine(baseURL: baseURL, apiKey: key, model: model, endpointMode: endpointMode, onPhaseChange: nil)
            _ = try await engine.translate(text: "test", sourceLanguageCode: "auto", targetLanguageCode: "en")

            settings.openAIBaseURL = baseURL
            settings.openAIModel = model
            settings.openAIEndpointModeRawValue = endpointMode.rawValue
            try KeychainStore.setString(key, for: "openAIAPIKey")
            log.info("OpenAI 配置已验证并保存")

            alertTitle = "保存成功"
            alertMessage = "已验证接口可用，并已保存配置。"
            showAlert = true
        } catch {
            log.error("验证失败：\(error.localizedDescription)")
            alertTitle = "验证失败"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    @MainActor
    private func clearKey() async {
        do {
            try KeychainStore.delete(for: "openAIAPIKey")
            draftAPIKey = ""
            alertTitle = "已清除"
            alertMessage = "API Key 已从系统 Keychain 中删除。"
            showAlert = true
            log.info("API Key 已清除")
        } catch {
            alertTitle = "清除失败"
            alertMessage = error.localizedDescription
            showAlert = true
            log.error("清除 Keychain 失败：\(error.localizedDescription)")
        }
    }
}
