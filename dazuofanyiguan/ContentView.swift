//
//  ContentView.swift
//  dazuofanyiguan
//
//  Created by AchordChan on 2025/12/19.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var toast: ToastCenter
    @EnvironmentObject private var log: LogStore
    @EnvironmentObject private var windowController: AppWindowController
    @EnvironmentObject private var clipboardMonitor: ClipboardDoubleCopyMonitor
    @EnvironmentObject private var hotkeyMonitor: GlobalHotkeyMonitor
    @EnvironmentObject private var miniTranslationController: MiniTranslationController
    @EnvironmentObject private var appleTranslationCoordinator: AppleTranslationCoordinator
    @EnvironmentObject private var vm: TranslatorViewModel
    @EnvironmentObject private var screenshotOCR: ScreenshotOCRCoordinator

    @Environment(\.openWindow) private var openWindow

    @State private var translationTimeoutTask: Task<Void, Never>?
    @State private var showTranslationTimeoutBanner: Bool = false

    @State private var translationStartDate: Date?
    @State private var translationWaitSeconds: Int = 0
    @State private var waitTickTask: Task<Void, Never>?

    @State private var showPermissionGuide: Bool = false
    @State private var showPermissionBanner: Bool = false
    @State private var didDismissPermissionBannerThisSession: Bool = false
    @State private var needsAccessibilityPermission: Bool = false
    @State private var needsScreenRecordingPermission: Bool = false
    @State private var hasRefreshedPermissionStatus: Bool = false

    private struct ShortcutRuntimeConfiguration: Equatable {
        let doubleCopyEnabled: Bool
        let doubleCopyWindowMs: Int
        let globalHotkeyEnabled: Bool
        let screenshotHotkeyEnabled: Bool
        let screenshotHotkeyKeyCode: Int
    }

    private struct MiniPresentationConfiguration: Equatable {
        let isEnabled: Bool
        let fontSize: Double
    }

    private struct HotkeyRuntimeState: Equatable {
        let isRunning: Bool
        let failureMessage: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            editors
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(
            WindowAccessor { window in
                // 布局回调中只绑定窗口身份与外观，避免 setContentSize 触发 AppKit 递归布局。
                windowController.bindMainWindow(
                    window,
                    title: "大佐翻译官 v\(appVersion)",
                    appearance: settings.appearance
                )
            }
            .frame(width: 0, height: 0)
        )
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if shouldShowGlobalHotkeyRecommendation {
                    GlobalHotkeyRecommendationBanner(
                        isRetry: hotkeyMonitor.lastStartFailureMessage != nil,
                        onEnable: enableRecommendedGlobalHotkey,
                        onIgnore: {
                            settings.snoozeGlobalHotkeyRecommendation()
                            toast.show("已忽略，本周不再提醒", style: .success)
                        },
                        onNeverRemind: {
                            settings.neverRecommendGlobalHotkey = true
                            toast.show("已关闭全局快捷键推荐", style: .success)
                        }
                    )
                    .padding(.horizontal, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if showPermissionBanner {
                    HomePermissionBanner(
                        needsAccessibility: needsAccessibilityPermission,
                        needsScreenRecording: needsScreenRecordingPermission,
                        onOpenGuide: {
                            showPermissionGuide = true
                        },
                        onIgnore: {
                            didDismissPermissionBannerThisSession = true
                            showPermissionBanner = false
                            toast.show("已暂时忽略权限提醒，可稍后在设置中放行权限", style: .success)
                        }
                    )
                    .padding(.horizontal, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showPermissionBanner)
                }

                if showTranslationTimeoutBanner {
                    TranslationTimeoutBanner(
                        onCancel: {
                            vm.cancelTranslation(clearInput: true)
                            showTranslationTimeoutBanner = false
                        },
                        waitedSeconds: translationWaitSeconds
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showTranslationTimeoutBanner)
                }
            }
            .padding(.bottom, 14)
        }
        .onAppear {
            refreshPermissionStatus()
            setupHotkeyMonitorIfNeeded()
            setupClipboardMonitorIfNeeded()
            miniTranslationController.applyFontSize(settings.miniTextFontSize)

            showPermissionGuide = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                refreshPermissionStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dazuofanyiguanOpenPermissionGuide)) { _ in
            refreshPermissionStatus()
            showPermissionGuide = true
        }
        .sheet(isPresented: $showPermissionGuide) {
            let needsAccessibility = !AXIsProcessTrusted()
            let showsScreenRecording = settings.screenshotHotkeyEnabled
            let needsScreenRecording = showsScreenRecording
                && !ScreenCapturePermission.hasPermission()

            PermissionGuideView(
                needsAccessibility: needsAccessibility,
                needsScreenRecording: needsScreenRecording,
                showsScreenRecordingPermission: showsScreenRecording,
                onOpenAccessibility: {
                    GlobalHotkeyMonitor.openAccessibilitySettings()
                },
                onOpenScreenRecording: {
                    ScreenCapturePermission.openScreenRecordingSettings()
                },
                onClose: {
                    showPermissionGuide = false
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .dazuofanyiguanTranslateNow)) { _ in
            vm.retryTranslateNow(settings: settings, log: log, toast: toast)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dazuofanyiguanClearInput)) { _ in
            vm.cancelTranslation(clearInput: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dazuofanyiguanCopyOutput)) { _ in
            vm.copyOutput(toast: toast)
        }
        .onChange(of: settings.engineTypeRawValue) { _, _ in
            vm.scheduleTranslate(settings: settings, log: log, toast: toast)
        }
        .onChange(of: settings.sourceLanguageCode) { _, _ in
            vm.scheduleTranslate(settings: settings, log: log, toast: toast)
        }
        .onChange(of: settings.targetLanguageCode) { _, _ in
            vm.scheduleTranslate(settings: settings, log: log, toast: toast)
        }
        .onChange(of: shortcutRuntimeConfiguration) { oldValue, newValue in
            if oldValue.screenshotHotkeyKeyCode != newValue.screenshotHotkeyKeyCode {
                hotkeyMonitor.stop()
            }
            setupHotkeyMonitorIfNeeded()
            setupClipboardMonitorIfNeeded()
            if oldValue.screenshotHotkeyEnabled != newValue.screenshotHotkeyEnabled {
                refreshPermissionStatus()
            }
        }
        .onChange(of: miniPresentationConfiguration) { oldValue, newValue in
            if oldValue.isEnabled, !newValue.isEnabled {
                miniTranslationController.dismiss(cancelTranslation: true)
            }
            if oldValue.fontSize != newValue.fontSize {
                miniTranslationController.applyFontSize(newValue.fontSize)
            }
        }
        .onChange(of: hotkeyRuntimeState) { oldValue, newValue in
            setupClipboardMonitorIfNeeded()
            if oldValue.failureMessage != newValue.failureMessage,
               let message = newValue.failureMessage {
                log.warn("\(message)，已使用剪贴板监听回退")
            }
        }
        .onChange(of: screenshotOCR.isRunning) { _, _ in
            setupClipboardMonitorIfNeeded()
        }
        .onChange(of: vm.translationToken) { _, token in
            stopTranslationTimeoutMonitoring()
            if vm.isTranslating, !vm.isWaitingForLanguageDownload {
                startTranslationTimeoutMonitoring(token: token)
            }
        }
        .onChange(of: vm.isWaitingForLanguageDownload) { _, isWaiting in
            stopTranslationTimeoutMonitoring()
            if !isWaiting, vm.isTranslating {
                startTranslationTimeoutMonitoring(token: vm.translationToken)
            }
        }
        .onChange(of: vm.isTranslating) { _, translating in
            stopTranslationTimeoutMonitoring()
            if translating, !vm.isWaitingForLanguageDownload {
                startTranslationTimeoutMonitoring(token: vm.translationToken)
            }
        }
    }

    private var shortcutRuntimeConfiguration: ShortcutRuntimeConfiguration {
        ShortcutRuntimeConfiguration(
            doubleCopyEnabled: settings.doubleCopyEnabled,
            doubleCopyWindowMs: settings.doubleCopyWindowMs,
            globalHotkeyEnabled: settings.globalHotkeyEnabled,
            screenshotHotkeyEnabled: settings.screenshotHotkeyEnabled,
            screenshotHotkeyKeyCode: settings.screenshotHotkeyKeyCode
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.2"
    }

    private var miniPresentationConfiguration: MiniPresentationConfiguration {
        MiniPresentationConfiguration(
            isEnabled: settings.miniModeEnabled,
            fontSize: settings.miniTextFontSize
        )
    }

    private var hotkeyRuntimeState: HotkeyRuntimeState {
        HotkeyRuntimeState(
            isRunning: hotkeyMonitor.isRunning,
            failureMessage: hotkeyMonitor.lastStartFailureMessage
        )
    }

    private var shouldShowGlobalHotkeyRecommendation: Bool {
        hasRefreshedPermissionStatus && settings.shouldRecommendGlobalHotkey(
            isAccessibilityTrusted: !needsAccessibilityPermission,
            globalMonitorFailed: settings.globalHotkeyEnabled
                && hotkeyMonitor.lastStartFailureMessage != nil
        )
    }

    private var header: some View {
        HomeToolbarView(
            sourceLanguageCode: $settings.sourceLanguageCode,
            targetLanguageCode: $settings.targetLanguageCode,
            miniModeEnabled: $settings.miniModeEnabled,
            engineTypeRawValue: $settings.engineTypeRawValue,
            appearance: settings.appearance,
            statusColor: statusColor,
            onSwapLanguages: {
                vm.reverseTranslate(settings: settings, log: log, toast: toast)
            },
            onToggleAppearance: toggleAppearance,
            onOpenConsole: {
                openWindow(id: "console")
            }
        )
    }

    private var editors: some View {
        HStack(spacing: 16) {
            HomeTranslationPanel(
                icon: "text.alignleft",
                title: "原文",
                subtitle: detectedSourceDescription,
                actions: {
                    if !vm.inputText.isEmpty {
                        Button {
                            vm.cancelTranslation(clearInput: true)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(HomePanelActionButtonStyle())
                        .help("清空原文")
                    }
                }
            ) {
                PlaceholderTextEditor(
                    text: $vm.inputText,
                    placeholder: "在这里输入或粘贴要翻译的文字…",
                    fontSize: AppTextFontSize.sanitized(settings.sourceTextFontSize)
                )
                    .onChange(of: vm.inputText) { _, _ in
                        if vm.shouldScheduleTranslationForCurrentInputChange() {
                            vm.scheduleTranslate(settings: settings, log: log, toast: toast)
                        }
                    }
                    .padding(8)
            }

            HomeTranslationPanel(
                icon: "character.bubble",
                title: "译文",
                subtitle: miniTranslationDirectionDescription,
                actions: {
                    if let model = vm.lastAIModelName,
                       vm.lastTranslationDurationMs != nil,
                       !vm.outputText.isEmpty {
                        AICompletedInfoButton(
                            model: model,
                            durationMs: vm.lastTranslationDurationMs,
                            estimatedTokens: vm.lastAIEstimatedTokens
                        )
                    }

                    Button {
                        vm.copyOutput(toast: toast)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(HomePanelActionButtonStyle())
                    .disabled(vm.outputText.isEmpty)
                    .help("复制译文")
                }
            ) {
                VStack(spacing: 0) {
                    ZStack {
                        OutputTextView(
                            text: $vm.outputText,
                            fontSize: AppTextFontSize.sanitized(settings.translatedTextFontSize)
                        )

                        if vm.outputText.isEmpty {
                            TranslationOutputEmptyState(isTranslating: vm.isTranslating)
                        }
                    }
                    .padding(8)

                    if vm.isTranslating {
                        if settings.engineType == .apple {
                            AppleTranslationStatusBar(
                                phaseText: vm.appleRequestPhase,
                                isWaitingForLanguageDownload: vm.isWaitingForLanguageDownload
                            )
                        } else if vm.isUsingAI, let model = vm.activeAIModelName {
                            aiTranslatingStatusBar(
                                model: model,
                                estimatedTokens: vm.estimatedAITokenCount,
                                phaseText: vm.aiRequestPhase
                            )
                        }
                    }
                }
                .contextMenu {
                    Button("复制译文") {
                        vm.copyOutput(toast: toast)
                    }
                    Button("重新翻译") {
                        vm.retryTranslateNow(settings: settings, log: log, toast: toast)
                    }
                    Divider()
                    Button("清空原文") {
                        vm.cancelTranslation(clearInput: true)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func aiTranslatingStatusBar(model: String, estimatedTokens: Int?, phaseText: String?) -> some View {
        AITranslatingStatusBar(model: model, estimatedTokens: estimatedTokens, phaseText: phaseText)
    }

    private var detectedSourceDescription: String? {
        guard settings.sourceLanguageCode == LanguagePreset.auto.code,
              let detected = vm.detectedSourceLanguageCode,
              !detected.isEmpty else {
            return nil
        }
        return "检测为\(LanguagePreset.displayName(for: detected))"
    }

    private var miniTranslationDirectionDescription: String? {
        guard let pair = vm.languagePairOverride else { return nil }
        let sourceCode = pair.sourceLanguageCode == LanguagePreset.auto.code
            ? (vm.detectedSourceLanguageCode ?? pair.sourceLanguageCode)
            : pair.sourceLanguageCode
        return "Mini 智能方向：\(LanguagePreset.displayName(for: sourceCode)) → \(LanguagePreset.displayName(for: pair.targetLanguageCode))"
    }

    private func toggleAppearance() {
        switch settings.appearance {
        case .dark:
            settings.appearance = .light
        case .light, .system:
            settings.appearance = .dark
        }
        miniTranslationController.applyAppearance(settings.appearance)
    }

    private func setupClipboardMonitorIfNeeded() {
        clipboardMonitor.onDoubleCopy = { text in
            Task { @MainActor in
                if screenshotOCR.isRunning {
                    return
                }
                handleTextShortcut(
                    text,
                    showClipboardToast: !settings.globalHotkeyEnabled || !hotkeyMonitor.isRunning
                )
            }
        }

        let needsRuntimeFallback = settings.globalHotkeyEnabled && !hotkeyMonitor.isRunning
        let shouldRun = !screenshotOCR.isRunning
            && ((settings.doubleCopyEnabled && !settings.globalHotkeyEnabled) || needsRuntimeFallback)
        if shouldRun {
            if !clipboardMonitor.isRunning || clipboardMonitor.runningWindowMs != settings.doubleCopyWindowMs {
                clipboardMonitor.start(windowMs: settings.doubleCopyWindowMs, log: log)
            }
        } else {
            if clipboardMonitor.isRunning {
                clipboardMonitor.stop()
                log.info("剪贴板监听已关闭")
            }
        }
    }

    private func setupHotkeyMonitorIfNeeded() {
        if settings.globalHotkeyEnabled {
            hotkeyMonitor.onDoubleCopy = { previousChangeCount in
                Task { @MainActor in
                    if screenshotOCR.isRunning {
                        return
                    }
                    guard let text = await clipboardText(after: previousChangeCount) else {
                        log.warn("未读取到本次复制的文字，已忽略快捷翻译")
                        return
                    }
                    handleTextShortcut(text, showClipboardToast: false)
                }
            }
        } else {
            hotkeyMonitor.onDoubleCopy = nil
        }

        hotkeyMonitor.onDoubleCut = {
            Task { @MainActor in
                if settings.screenshotHotkeyEnabled {
                    let needsAccessibility = !AXIsProcessTrusted()
                    let needsScreenRecording = !ScreenCapturePermission.hasPermission()
                    if needsAccessibility || needsScreenRecording {
                        refreshPermissionStatus()
                        showPermissionGuide = true
                        return
                    }
                    screenshotOCR.start(settings: settings, log: log, toast: toast)
                }
            }
        }

        if settings.globalHotkeyEnabled || settings.screenshotHotkeyEnabled {
            hotkeyMonitor.start(windowMs: settings.doubleCopyWindowMs, doubleCutKeyCode: settings.screenshotHotkeyKeyCode)
        } else {
            hotkeyMonitor.stop()
        }
    }

    private func enableRecommendedGlobalHotkey() {
        if hotkeyMonitor.isRunning || hotkeyMonitor.isStarting
            || hotkeyMonitor.lastStartFailureMessage != nil {
            hotkeyMonitor.stop()
        }
        settings.globalHotkeyEnabled = true
        settings.doubleCopyEnabled = false
        setupHotkeyMonitorIfNeeded()
        setupClipboardMonitorIfNeeded()
    }

    private func handleTextShortcut(_ text: String, showClipboardToast: Bool) {
        if settings.miniModeEnabled {
            miniTranslationController.translate(
                text: text,
                settings: settings,
                viewModel: vm,
                appleTranslationCoordinator: appleTranslationCoordinator,
                windowController: windowController,
                toast: toast,
                log: log
            )
            return
        }

        windowController.showAndActivate()
        vm.applyExternalText(text, settings: settings, log: log, toast: toast)

        if showClipboardToast {
            switch settings.engineType {
            case .google, .openAICompatible:
                toast.show("已从剪贴板读取文字，将发送到在线翻译服务", style: .info)
            case .apple:
                toast.show("已获取剪贴板文字并开始翻译", style: .success)
            }
        }
    }

    private func clipboardText(after previousChangeCount: Int) async -> String? {
        let pasteboard = NSPasteboard.general
        for _ in 0..<8 {
            if pasteboard.changeCount != previousChangeCount {
                let text = pasteboard.string(forType: .string) ?? ""
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : text
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private var statusColor: Color {
        if vm.isTranslating {
            return .orange
        }
        if let err = vm.lastErrorMessage, !err.isEmpty {
            return .red
        }
        return .green
    }

    private func startTranslationTimeoutMonitoring(token: Int) {
        translationStartDate = Date()
        translationWaitSeconds = 0

        waitTickTask?.cancel()
        waitTickTask = Task { @MainActor in
            while vm.isTranslating, !vm.isWaitingForLanguageDownload {
                let base = translationStartDate ?? Date()
                translationWaitSeconds = max(0, Int(Date().timeIntervalSince(base)))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
        }

        translationTimeoutTask?.cancel()
        translationTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Task.isCancelled { return }
            if vm.isTranslating,
               !vm.isWaitingForLanguageDownload,
               vm.translationToken == token {
                showTranslationTimeoutBanner = true
            }
        }
    }

    private func stopTranslationTimeoutMonitoring() {
        translationTimeoutTask?.cancel()
        translationTimeoutTask = nil
        showTranslationTimeoutBanner = false

        waitTickTask?.cancel()
        waitTickTask = nil
        translationStartDate = nil
        translationWaitSeconds = 0
    }

    private func refreshPermissionStatus() {
        let permissionWasMissing = needsAccessibilityPermission
        let trusted = AXIsProcessTrusted()
        let screenOK = ScreenCapturePermission.hasPermission()

        needsAccessibilityPermission = !trusted
        needsScreenRecordingPermission = settings.screenshotHotkeyEnabled && !screenOK
        hasRefreshedPermissionStatus = true
        showPermissionBanner = (needsAccessibilityPermission || needsScreenRecordingPermission)
            && !didDismissPermissionBannerThisSession

        if !trusted {
            // 权限暂不可用时只做运行时回退，不永久改写用户偏好。
            if hotkeyMonitor.isRunning || hotkeyMonitor.isStarting {
                hotkeyMonitor.stop()
            }
            setupClipboardMonitorIfNeeded()
        }

        let didPreferGlobal = settings.preferGlobalHotkeyWhenAvailable(
            isAccessibilityTrusted: trusted,
            permissionWasMissing: permissionWasMissing
        )
        let shouldRetryHotkey = trusted
            && (settings.globalHotkeyEnabled || settings.screenshotHotkeyEnabled)
            && !hotkeyMonitor.isRunning
            && !hotkeyMonitor.isStarting
        if didPreferGlobal || shouldRetryHotkey {
            setupHotkeyMonitorIfNeeded()
            setupClipboardMonitorIfNeeded()
        }

        // 截图翻译快捷键由全局热键触发：需要“辅助功能 + 屏幕录制”都已放行。
        let sKey = "didAutoEnableScreenshotHotkeyV2"
        if trusted, screenOK, !UserDefaults.standard.bool(forKey: sKey) {
            settings.screenshotHotkeyEnabled = true
            UserDefaults.standard.set(true, forKey: sKey)
        }
    }

}

#Preview {
    let settings = AppSettings()
    let toast = ToastCenter()
    let log = LogStore()
    let windowController = AppWindowController()
    let clipboardMonitor = ClipboardDoubleCopyMonitor()
    let hotkeyMonitor = GlobalHotkeyMonitor()
    let miniTranslationController = MiniTranslationController()
    let appleTranslationCoordinator = AppleTranslationCoordinator()
    let vm = TranslatorViewModel(appleTranslationCoordinator: appleTranslationCoordinator)
    let screenshotOCR = ScreenshotOCRCoordinator(
        appleTranslationCoordinator: AppleTranslationCoordinator()
    )

    ContentView()
        .appleTranslationSession(using: appleTranslationCoordinator)
        .environmentObject(settings)
        .environmentObject(toast)
        .environmentObject(log)
        .environmentObject(windowController)
        .environmentObject(clipboardMonitor)
        .environmentObject(hotkeyMonitor)
        .environmentObject(miniTranslationController)
        .environmentObject(appleTranslationCoordinator)
        .environmentObject(vm)
        .environmentObject(screenshotOCR)
        .frame(width: 960, height: 620)
}
