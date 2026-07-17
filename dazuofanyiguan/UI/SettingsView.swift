import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: LogStore
    @EnvironmentObject private var hotkeyMonitor: GlobalHotkeyMonitor
    @EnvironmentObject private var updater: AppUpdaterController

    @StateObject private var windowBehavior = SettingsWindowBehavior()

    @State private var selectedSection: SettingsSection = .general
    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    @State private var draftAPIKey = ""
    @State private var draftEndpointModeRawValue = OpenAIEndpointMode.chatCompletions.rawValue
    @State private var loaded = false
    @State private var isSaving = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var openPermissionGuideAfterAlert = false
    @State private var hasAccessibilityPermission = false
    @State private var hasScreenRecordingPermission = false
    @State private var hasLoadedPermissionStatus = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            VStack(spacing: 0) {
                paneHeader
                Divider()

                ScrollView {
                    selectedPane
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                }
                .scrollIndicators(.automatic)
                .id(selectedSection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 860, height: 650)
        .background(windowAccessor)
        .onAppear(perform: loadSettings)
        .onChange(of: settings.globalHotkeyEnabled, handleGlobalHotkeyChange)
        .onChange(of: settings.screenshotHotkeyEnabled, handleScreenshotHotkeyChange)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
            if settings.globalHotkeyEnabled,
               hotkeyMonitor.isTrusted,
               !hotkeyMonitor.isRunning {
                hotkeyMonitor.start(
                    windowMs: settings.doubleCopyWindowMs,
                    doubleCutKeyCode: settings.screenshotHotkeyKeyCode
                )
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好的") {
                guard openPermissionGuideAfterAlert else { return }
                openPermissionGuideAfterAlert = false
                openPermissionGuide()
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("大佐翻译官")
                        .font(.system(size: 14, weight: .semibold))
                    Text("设置")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text("版本 \(appVersion)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 14)
        }
        .frame(width: 196)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedSection.title)
                .font(.system(size: 22, weight: .semibold))
            Text(selectedSection.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsPane(
                engineTypeRawValue: $settings.engineTypeRawValue,
                appearanceRawValue: $settings.appearanceRawValue,
                sourceTextFontSize: $settings.sourceTextFontSize,
                translatedTextFontSize: $settings.translatedTextFontSize,
                miniTextFontSize: $settings.miniTextFontSize,
                draftBaseURL: $draftBaseURL,
                draftModel: $draftModel,
                draftAPIKey: $draftAPIKey,
                draftEndpointModeRawValue: $draftEndpointModeRawValue,
                isSaving: isSaving,
                onValidateAndSave: {
                    Task { @MainActor in
                        await validateAndSave()
                    }
                },
                onClearKey: {
                    Task { @MainActor in
                        await clearKey()
                    }
                }
            )

        case .shortcuts:
            ShortcutSettingsPane(
                textShortcutEnabled: textShortcutEnabledBinding,
                shortcutMode: textShortcutModeBinding,
                miniModeEnabled: $settings.miniModeEnabled,
                doubleCopyWindowMs: $settings.doubleCopyWindowMs,
                hasAccessibilityPermission: hasAccessibilityPermission,
                onOpenPermissionGuide: openPermissionGuide
            )

        case .screenshot:
            ScreenshotSettingsPane(
                enabled: $settings.screenshotHotkeyEnabled,
                hotkeyKeyCode: $settings.screenshotHotkeyKeyCode,
                freezeBackgroundEnabled: $settings.screenshotFreezeBackgroundEnabled,
                hasAccessibilityPermission: hasAccessibilityPermission,
                hasScreenRecordingPermission: hasScreenRecordingPermission,
                onOpenPermissionGuide: openPermissionGuide
            )

        case .help:
            HelpAboutSettingsPane(
                appVersion: appVersion,
                canCheckForUpdates: updater.canCheckForUpdates,
                onCheckForUpdates: updater.checkForUpdates
            )
        }
    }

    private var textShortcutEnabledBinding: Binding<Bool> {
        Binding {
            settings.globalHotkeyEnabled || settings.doubleCopyEnabled
        } set: { enabled in
            if enabled {
                if hasAccessibilityPermission {
                    settings.globalHotkeyEnabled = true
                } else {
                    settings.doubleCopyEnabled = true
                }
            } else {
                settings.globalHotkeyEnabled = false
                settings.doubleCopyEnabled = false
            }
        }
    }

    private var textShortcutModeBinding: Binding<TextShortcutMode> {
        Binding {
            settings.globalHotkeyEnabled ? .global : .clipboard
        } set: { mode in
            switch mode {
            case .global:
                settings.globalHotkeyEnabled = true
            case .clipboard:
                settings.globalHotkeyEnabled = false
                settings.doubleCopyEnabled = true
            }
        }
    }

    private var windowAccessor: some View {
        WindowAccessor { window in
            guard let window else { return }
            window.title = "设置"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.minSize = NSSize(width: 780, height: 590)
            windowBehavior.attach(window)
        }
        .frame(width: 0, height: 0)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2"
    }

    private func loadSettings() {
        refreshPermissionStatus()
        guard !loaded else { return }
        loaded = true
        draftBaseURL = settings.openAIBaseURL
        draftModel = settings.openAIModel
        draftEndpointModeRawValue = settings.openAIEndpointModeRawValue

        do {
            draftAPIKey = (try KeychainStore.getString(for: "openAIAPIKey")) ?? ""
        } catch {
            log.error("读取 Keychain 失败：\(error.localizedDescription)")
        }

        // 权限暂不可用时不永久改写用户偏好，只停止运行中的全局热键。
        if settings.globalHotkeyEnabled, !hotkeyMonitor.isTrusted {
            if hotkeyMonitor.isRunning || hotkeyMonitor.isStarting {
                hotkeyMonitor.stop()
            }
        }

    }

    private func refreshPermissionStatus() {
        let permissionWasMissing = hasLoadedPermissionStatus && !hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenRecordingPermission = ScreenCapturePermission.hasPermission()
        hasLoadedPermissionStatus = true

        if !hasAccessibilityPermission {
            if hotkeyMonitor.isRunning || hotkeyMonitor.isStarting {
                hotkeyMonitor.stop()
            }
        }

        let didPreferGlobal = settings.preferGlobalHotkeyWhenAvailable(
            isAccessibilityTrusted: hasAccessibilityPermission,
            permissionWasMissing: permissionWasMissing
        )
        if (didPreferGlobal || settings.globalHotkeyEnabled || settings.screenshotHotkeyEnabled),
           hasAccessibilityPermission,
           !hotkeyMonitor.isRunning,
           !hotkeyMonitor.isStarting {
            hotkeyMonitor.start(
                windowMs: settings.doubleCopyWindowMs,
                doubleCutKeyCode: settings.screenshotHotkeyKeyCode
            )
        }
    }

    private func handleGlobalHotkeyChange(_ oldValue: Bool, _ enabled: Bool) {
        guard enabled else { return }
        if hotkeyMonitor.isTrusted {
            settings.doubleCopyEnabled = false
            hasAccessibilityPermission = true
        } else {
            // 保留用户偏好为全局快捷键；运行时回退到剪贴板监听，并引导授权。
            if hotkeyMonitor.isRunning || hotkeyMonitor.isStarting {
                hotkeyMonitor.stop()
            }
            alertTitle = "需要辅助功能权限"
            alertMessage = "已临时使用剪贴板监听。授权辅助功能后，会按你的偏好恢复全局快捷键。"
            openPermissionGuideAfterAlert = true
            showAlert = true
        }
    }

    private func handleScreenshotHotkeyChange(_ oldValue: Bool, _ enabled: Bool) {
        guard enabled else { return }
        refreshPermissionStatus()
        let needsAccessibility = !hasAccessibilityPermission
        let needsScreenRecording = !hasScreenRecordingPermission
        guard needsAccessibility || needsScreenRecording else { return }

        settings.screenshotHotkeyEnabled = false
        alertTitle = "需要权限才能启用"
        if needsAccessibility && needsScreenRecording {
            alertMessage = "截图翻译快捷键需要辅助功能和屏幕录制权限。"
        } else if needsAccessibility {
            alertMessage = "截图翻译快捷键需要辅助功能权限。"
        } else {
            alertMessage = "截图翻译需要屏幕录制权限。"
        }
        openPermissionGuideAfterAlert = true
        showAlert = true
    }

    private func openPermissionGuide() {
        NotificationCenter.default.post(
            name: .dazuofanyiguanOpenPermissionGuide,
            object: nil
        )
    }

    @MainActor
    private func validateAndSave() async {
        isSaving = true
        defer { isSaving = false }

        let baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointMode = OpenAIEndpointMode(rawValue: draftEndpointModeRawValue)
            ?? .chatCompletions

        guard !baseURL.isEmpty, !model.isEmpty, !key.isEmpty else {
            presentAlert(
                title: "无法保存",
                message: "Base URL、模型和 API Key 均不能为空。"
            )
            return
        }

        do {
            _ = try OpenAIEndpointValidator.validatedBaseURL(from: baseURL)
        } catch {
            presentAlert(title: "无法保存", message: error.localizedDescription)
            return
        }

        do {
            let engine = OpenAICompatibleEngine(
                baseURL: baseURL,
                apiKey: key,
                model: model,
                endpointMode: endpointMode,
                onPhaseChange: nil
            )
            _ = try await engine.translate(
                text: "test",
                sourceLanguageCode: "auto",
                targetLanguageCode: "en"
            )

            settings.openAIBaseURL = baseURL
            settings.openAIModel = model
            settings.openAIEndpointModeRawValue = endpointMode.rawValue
            try KeychainStore.setString(key, for: "openAIAPIKey")
            log.info("OpenAI 配置已验证并保存")
            presentAlert(title: "保存成功", message: "接口验证通过，配置已保存。")
        } catch {
            log.error("验证失败：\(error.localizedDescription)")
            presentAlert(title: "验证失败", message: error.localizedDescription)
        }
    }

    @MainActor
    private func clearKey() async {
        do {
            try KeychainStore.delete(for: "openAIAPIKey")
            draftAPIKey = ""
            log.info("API Key 已清除")
            presentAlert(title: "已清除", message: "API Key 已从系统钥匙串中删除。")
        } catch {
            log.error("清除 Keychain 失败：\(error.localizedDescription)")
            presentAlert(title: "清除失败", message: error.localizedDescription)
        }
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
