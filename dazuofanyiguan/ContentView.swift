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
    @EnvironmentObject private var vm: TranslatorViewModel
    @EnvironmentObject private var screenshotOCR: ScreenshotOCRCoordinator

    @Environment(\.openWindow) private var openWindow

    @State private var isHoveringOutput: Bool = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            editors
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(
            WindowAccessor { window in
                guard let window else { return }

                window.title = "大佐翻译官-V1"
                windowController.window = window
                window.identifier = AppWindowController.mainWindowIdentifier
                window.isReleasedWhenClosed = false
                window.delegate = windowController

                windowController.applyAppearance(settings.appearance, to: window)

                if window.minSize.width != 980 || window.minSize.height != 640 {
                    window.minSize = NSSize(width: 980, height: 640)
                }
                if window.frame.size.width != 980 || window.frame.size.height != 640 {
                    window.setContentSize(NSSize(width: 980, height: 640))
                }

                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
                window.isMovableByWindowBackground = false
                window.styleMask.remove(.borderless)
                window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
                if #available(macOS 11.0, *) {
                    window.titlebarSeparatorStyle = .none
                }
                windowController.configureChrome(window)
            }
            .frame(width: 0, height: 0)
        )
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if showPermissionBanner {
                    PermissionReminderBanner(
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
                    .padding(.horizontal, 16)
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
            if settings.globalHotkeyEnabled, !hotkeyMonitor.isTrusted {
                settings.globalHotkeyEnabled = false
                settings.doubleCopyEnabled = true
            }

            setupHotkeyMonitorIfNeeded()
            setupClipboardMonitorIfNeeded()

            refreshPermissionStatus()
            showPermissionGuide = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dazuofanyiguanOpenPermissionGuide)) { _ in
            refreshPermissionStatus()
            showPermissionGuide = true
        }
        .sheet(isPresented: $showPermissionGuide) {
            let needsAccessibility = !AXIsProcessTrusted()
            let needsScreenRecording = !ScreenCapturePermission.hasPermission()

            PermissionGuideView(
                needsAccessibility: needsAccessibility,
                needsScreenRecording: needsScreenRecording,
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
        .onChange(of: settings.doubleCopyEnabled) { _, _ in
            setupClipboardMonitorIfNeeded()
        }
        .onChange(of: settings.doubleCopyWindowMs) { _, _ in
            setupHotkeyMonitorIfNeeded()
            setupClipboardMonitorIfNeeded()
        }
        .onChange(of: settings.globalHotkeyEnabled) { _, _ in
            setupHotkeyMonitorIfNeeded()
            setupClipboardMonitorIfNeeded()
        }
        .onChange(of: hotkeyMonitor.isRunning) { _, _ in
            setupClipboardMonitorIfNeeded()
        }
        .onChange(of: screenshotOCR.isRunning) { _, _ in
            setupClipboardMonitorIfNeeded()
        }
        .onChange(of: vm.translationToken) { _, token in
            translationTimeoutTask?.cancel()
            showTranslationTimeoutBanner = false
            if vm.isTranslating {
                translationStartDate = Date()
                translationWaitSeconds = 0

                waitTickTask?.cancel()
                waitTickTask = Task { @MainActor in
                    while vm.isTranslating {
                        let base = translationStartDate ?? Date()
                        translationWaitSeconds = max(0, Int(Date().timeIntervalSince(base)))
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return }
                    }
                }

                translationTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if Task.isCancelled { return }
                    if vm.isTranslating, vm.translationToken == token {
                        showTranslationTimeoutBanner = true
                    }
                }
            }
        }
        .onChange(of: vm.isTranslating) { _, translating in
            if !translating {
                translationTimeoutTask?.cancel()
                showTranslationTimeoutBanner = false

                waitTickTask?.cancel()
                waitTickTask = nil
                translationStartDate = nil
                translationWaitSeconds = 0
            }
        }
    }

    private struct TranslationTimeoutBanner: View {
        let onCancel: () -> Void

        let waitedSeconds: Int

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("翻译耗时较长")
                        .font(.system(size: 13, weight: .semibold))
                    Text("这段内容较长，翻译可能需要更久。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text("当前已等待\(waitedSeconds)秒")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Button("取消翻译") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
            .frame(maxWidth: 720)
            .padding(.horizontal, 12)
        }
    }

    private struct AICompletedInfoButton: View {
        let model: String
        let durationMs: Int?
        let estimatedTokens: Int?

        @State private var showInfo: Bool = false

        var body: some View {
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("AI 请求已完成")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(model)
                            .font(.system(size: 12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("运行时间")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let durationMs {
                            Text("\(durationMs) ms")
                                .font(.system(size: 12))
                        } else {
                            Text("未知")
                                .font(.system(size: 12))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("预计消耗")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let estimatedTokens {
                            Text("Token 数：\(estimatedTokens)")
                                .font(.system(size: 12))
                        } else {
                            Text("Token 数：未知")
                                .font(.system(size: 12))
                        }
                    }
                }
                .padding(14)
                .frame(width: 260)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            languageBar

            Spacer(minLength: 12)

            Button {
                toggleAppearance()
            } label: {
                Image(systemName: settings.appearance == .dark ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .dsPill()
            }
            .buttonStyle(.plain)
            .help("切换主题")

            Button {
                openWindow(id: "console")
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .dsPill()
            }
            .buttonStyle(.plain)
            .help("打开控制台")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .dsPill()
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private var engineStatusPill: some View {
        HStack(spacing: 10) {
            Image(systemName: settings.engineType == .google ? "g.circle.fill" : "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(settings.engineType == .google ? .blue : .purple)

            Text("当前翻译服务提供")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(settings.engineType.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .opacity(0.9)
        }
        .dsPill()
        .help("在设置中切换翻译服务")
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            LanguageSearchPicker(
                title: "源语言",
                allowAuto: true,
                options: LanguagePreset.common,
                selection: $settings.sourceLanguageCode
            )

            Button {
                vm.reverseTranslate(settings: settings, log: log, toast: toast)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .dsPill()
            }
            .buttonStyle(.plain)
            .help("一键反向翻译")

            LanguageSearchPicker(
                title: "目标语言",
                allowAuto: false,
                options: LanguagePreset.common,
                selection: $settings.targetLanguageCode
            )

            engineStatusPill
        }
    }

    private var editors: some View {
        HStack(spacing: 14) {
            editorPanel(title: sourcePanelTitle, detected: nil) {
                PlaceholderTextEditor(text: $vm.inputText, placeholder: "在这里输入或粘贴要翻译的文字…")
                    .onChange(of: vm.inputText) { _, _ in
                        vm.scheduleTranslate(settings: settings, log: log, toast: toast)
                    }
            }

            editorPanel(
                title: "译文",
                detected: nil
            ) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        OutputTextView(text: $vm.outputText)

                        if vm.outputText.isEmpty {
                            Text(vm.isTranslating ? "正在翻译…" : "翻译结果会显示在这里")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .padding(.top, 10)
                                .allowsHitTesting(false)
                        }
                    }

                    if vm.isTranslating, vm.isUsingAI, let model = vm.activeAIModelName {
                        aiTranslatingStatusBar(model: model, estimatedTokens: vm.estimatedAITokenCount, phaseText: vm.aiRequestPhase)
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
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 6) {
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        .buttonStyle(.plain)
                        .help("复制译文")
                    }
                    .padding(.trailing, 2)
                    .padding(.bottom, 2)
                    .opacity(isHoveringOutput && !vm.outputText.isEmpty ? 1.0 : 0.0)
                    .animation(.easeOut(duration: 0.12), value: isHoveringOutput)
                }
                .onHover { hovering in
                    isHoveringOutput = hovering
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func aiTranslatingStatusBar(model: String, estimatedTokens: Int?, phaseText: String?) -> some View {
        AITranslatingStatusBar(model: model, estimatedTokens: estimatedTokens, phaseText: phaseText)
    }

    private struct AITranslatingStatusBar: View {
        let model: String
        let estimatedTokens: Int?
        let phaseText: String?

        @State private var showInfo: Bool = false

        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 4
                let dots = String(repeating: "。", count: step)
                HStack(spacing: 8) {
                    Button {
                        showInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showInfo) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.secondary)
                                Text("AI 翻译详情")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 0)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("当前状态")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(phaseText ?? "正在等待服务端响应")
                                    .font(.system(size: 12))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("预计消耗")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                if let estimatedTokens {
                                    Text("Token 数：\(estimatedTokens)")
                                        .font(.system(size: 12))
                                } else {
                                    Text("Token 数：未知")
                                        .font(.system(size: 12))
                                }
                            }
                        }
                        .padding(14)
                        .frame(width: 260)
                    }

                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("正在调用AI模型-\(model)翻译，请稍候\(dots)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(
                    Divider(),
                    alignment: .top
                )
            }
        }
    }

    private struct OutputTextView: NSViewRepresentable {
        @Binding var text: String

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.scrollerKnobStyle = .default

            let textView = NSTextView()
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.isRichText = false
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = NSFont.systemFont(ofSize: 15)
            textView.textColor = NSColor.labelColor
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes[.paragraphStyle] = paragraphStyle
            textView.textContainerInset = NSSize(width: 8, height: 10)
            textView.string = text
            if !text.isEmpty {
                textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: (text as NSString).length))
            }
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.heightTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

            scrollView.documentView = textView
            scrollView.verticalScroller?.controlSize = .mini
            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let textView = nsView.documentView as? NSTextView else { return }
            if textView.string != text {
                textView.string = text
                if let paragraphStyle = textView.defaultParagraphStyle, !text.isEmpty {
                    textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: (text as NSString).length))
                }
            }
        }
    }

    private func editorPanel<Content: View>(
        title: String,
        detected: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let detected {
                    Text(detected)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
                .dsCard()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let error = vm.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text("")
                    .font(.system(size: 12))
            }

            Spacer()
        }
        .padding(.top, 2)
    }

    private var sourcePanelTitle: String {
        guard settings.sourceLanguageCode == LanguagePreset.auto.code else { return "原文" }
        guard let detected = vm.detectedSourceLanguageCode, !detected.isEmpty else { return "原文" }
        return "原文(\(LanguagePreset.displayName(for: detected)))"
    }

    private func toggleAppearance() {
        switch settings.appearance {
        case .dark:
            settings.appearance = .light
        case .light, .system:
            settings.appearance = .dark
        }
    }

    private func setupClipboardMonitorIfNeeded() {
        clipboardMonitor.onDoubleCopy = { text in
            Task { @MainActor in
                if screenshotOCR.isRunning {
                    return
                }
                windowController.showAndActivate()
                vm.applyExternalText(text, settings: settings, log: log, toast: toast)
                // 只在“监听剪贴板”模式下提示。
                // 全局快捷键模式下不提示（否则用户会误以为是剪贴板监听触发）。
                if !settings.globalHotkeyEnabled {
                    toast.show("已获取剪贴板文字并开始翻译", style: .success)
                }
            }
        }

        let shouldRun = settings.doubleCopyEnabled && !settings.globalHotkeyEnabled && !screenshotOCR.isRunning
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
            hotkeyMonitor.onDoubleCopy = {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                Task { @MainActor in
                    if screenshotOCR.isRunning {
                        return
                    }
                    windowController.showAndActivate()
                    vm.applyExternalText(text, settings: settings, log: log, toast: toast)
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

    private var statusColor: Color {
        if vm.isTranslating {
            return .orange
        }
        if let err = vm.lastErrorMessage, !err.isEmpty {
            return .red
        }
        return .green
    }

    private func refreshPermissionStatus() {
        let trusted = AXIsProcessTrusted()
        let screenOK = ScreenCapturePermission.hasPermission()

        needsAccessibilityPermission = !trusted
        needsScreenRecordingPermission = !screenOK
        showPermissionBanner = (!trusted || !screenOK) && !didDismissPermissionBannerThisSession

        // 权限放行后，自动切换到“更好的默认体验”（只自动执行一次）。
        let gKey = "didAutoEnableGlobalHotkeyV1"
        if trusted, !UserDefaults.standard.bool(forKey: gKey) {
            settings.globalHotkeyEnabled = true
            settings.doubleCopyEnabled = false
            UserDefaults.standard.set(true, forKey: gKey)
        }

        // 截图翻译快捷键由全局热键触发：需要“辅助功能 + 屏幕录制”都已放行。
        let sKey = "didAutoEnableScreenshotHotkeyV2"
        if trusted, screenOK, !UserDefaults.standard.bool(forKey: sKey) {
            settings.screenshotHotkeyEnabled = true
            UserDefaults.standard.set(true, forKey: sKey)
        }
    }

    private struct PermissionReminderBanner: View {
        let needsAccessibility: Bool
        let needsScreenRecording: Bool
        let onOpenGuide: () -> Void
        let onIgnore: () -> Void

        private var message: String {
            if needsAccessibility && needsScreenRecording { return "权限未放行：辅助功能、屏幕录制" }
            if needsAccessibility { return "权限未放行：辅助功能" }
            if needsScreenRecording { return "权限未放行：屏幕录制" }
            return "权限未放行"
        }

        var body: some View {
            HStack(spacing: 12) {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("忽略") {
                    onIgnore()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("去授权") {
                    onOpenGuide()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.22), lineWidth: 1)
            )
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
    let vm = TranslatorViewModel()
    let screenshotOCR = ScreenshotOCRCoordinator()

    ContentView()
        .environmentObject(settings)
        .environmentObject(toast)
        .environmentObject(log)
        .environmentObject(windowController)
        .environmentObject(clipboardMonitor)
        .environmentObject(hotkeyMonitor)
        .environmentObject(vm)
        .environmentObject(screenshotOCR)
        .frame(width: 960, height: 620)
}
