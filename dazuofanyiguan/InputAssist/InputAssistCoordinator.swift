import AppKit
import ApplicationServices
import Foundation

/// 本地统计。不记录原文和译文正文。
struct InputAssistMetrics: Equatable {
    var shortcutTriggerCount = 0
    var selectionAutoShowCount = 0
    var candidateShowCount = 0
    var candidateCommitCount = 0
    var candidateCopyCount = 0
    var cacheHitCount = 0
    var axReplaceCount = 0
    var editorPasteCount = 0
    var alreadyMatchingCount = 0
    var safeAbortCount = 0
    var dismissByEscapeCount = 0
    /// 为多少个 Chromium / Electron 应用主动打开过辅助功能树。
    var chromiumAccessibilityEnabledCount = 0
}

/// 选中文本翻译与安全提交的主编排。
///
/// 正式主路径：`选中文本 → 快捷键 → 候选 → 精确替换 / 复制`。
/// 选区完成后自动显示是默认关闭的可选增强，不再监听连续输入或猜测输入法状态。
@MainActor
final class InputAssistCoordinator: ObservableObject {
    @Published private(set) var metrics = InputAssistMetrics()
    @Published private(set) var lastStatusMessage: String?

    private let settings: InputAssistSettings
    private let hotkeyMonitor = InputAssistHotkeyMonitor()
    private let selectionMonitor = InputAssistSelectionMonitor()
    private let panelController = CandidatePanelController()
    private let feedbackPanelController = InputAssistFeedbackPanelController()
    private let applePool = InputAssistAppleTranslationPool()
    private lazy var candidateService = CandidateService(applePool: applePool)

    private var appSettings: AppSettings?
    private var log: LogStore?
    private var toast: ToastCenter?

    private let isAccessibilityTrustedProvider: () -> Bool
    private var didObserveActivation = false
    private var currentSession: CandidateSession?
    private var currentRequest: CandidateTranslationRequest?
    private var translationTask: Task<Void, Never>?
    private var retryTasks: [Task<Void, Never>] = []
    private var isCommitting = false

    var hotkeyStatus: InputAssistHotkeyStatus { hotkeyMonitor.status }
    var isAccessibilityTrusted: Bool { isAccessibilityTrustedProvider() }

    init(
        settings: InputAssistSettings,
        isAccessibilityTrustedProvider: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.settings = settings
        self.isAccessibilityTrustedProvider = isAccessibilityTrustedProvider

        hotkeyMonitor.onTrigger = { [weak self] in
            self?.handleShortcutTrigger()
        }
        selectionMonitor.onSelection = { [weak self] capture in
            self?.handleAutomaticSelection(capture)
        }
        selectionMonitor.isSelectionAllowed = { [weak self] in
            self?.isAutomaticSelectionAllowed() ?? false
        }

        panelController.onCommit = { [weak self] index in
            self?.commitCandidate(at: index)
        }
        panelController.onCopy = { [weak self] index in
            self?.copyCandidate(at: index)
        }
        panelController.onRetry = { [weak self] index in
            self?.retryCandidate(at: index)
        }
        panelController.onDismiss = { [weak self] reason in
            self?.handleDismiss(reason: reason)
        }
    }

    func activate(appSettings: AppSettings, log: LogStore, toast: ToastCenter) {
        self.appSettings = appSettings
        self.log = log
        self.toast = toast
        observeApplicationActivationIfNeeded()
        applyEnabledState()
    }

    private func observeApplicationActivationIfNeeded() {
        guard !didObserveActivation else { return }
        didObserveActivation = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyEnabledStateIfPermissionArrived()
            }
        }
    }

    func reapplyEnabledStateIfPermissionArrived() {
        guard settings.isEnabled, isAccessibilityTrusted else { return }
        guard !hotkeyMonitor.status.isActive else { return }
        applyEnabledState()
    }

    func applyEnabledState() {
        guard settings.isEnabled else {
            hotkeyMonitor.unregister()
            selectionMonitor.stop()
            panelController.dismiss(reason: .featureDisabled)
            applePool.shutdown()
            lastStatusMessage = nil
            return
        }

        guard isAccessibilityTrusted else {
            hotkeyMonitor.unregister()
            selectionMonitor.stop()
            lastStatusMessage = "需要辅助功能权限才能读取和替换选中文本"
            log?.warn("Input Assist 未启动：当前构建尚未获得辅助功能权限")
            return
        }

        hotkeyMonitor.register(settings.shortcut)
        applePool.prepare(slotCount: settings.targetLanguageCodes.count)

        if settings.isSelectionAutoShowEnabled {
            if !selectionMonitor.start() {
                log?.warn("Input Assist 无法启动选区自动显示监听")
            }
        } else {
            selectionMonitor.stop()
        }

        lastStatusMessage = hotkeyMonitor.status.isActive
            ? nil
            : "快捷键 \(settings.shortcut.displayString) 注册失败，可能被其它应用占用"
    }

    func deactivate() {
        hotkeyMonitor.unregister()
        selectionMonitor.stop()
        cancelInFlightTranslations()
        panelController.dismiss(reason: .featureDisabled)
        applePool.shutdown()
    }

    /// 测试页按钮与全局快捷键共用同一入口。
    func triggerManually() {
        handleShortcutTrigger()
    }

    private func handleShortcutTrigger() {
        guard settings.isEnabled, let appSettings else { return }
        guard !isCommitting else { return }
        guard isAccessibilityTrusted else {
            lastStatusMessage = "需要辅助功能权限才能读取和替换选中文本"
            toast?.show("选中文本翻译需要辅助功能权限", style: .warning)
            return
        }

        let identity = InputAssistAppIdentity.frontmost()
        guard allowsApplication(identity) else {
            log?.info("Input Assist 跳过当前应用（应用范围设置）")
            // 原来这里是静默返回的：用户在被排除的应用里按快捷键，什么都不会发生，
            // 也无从知道是被自己的设置挡掉的。
            toast?.show("当前应用在选区翻译的排除列表中", style: .info)
            return
        }

        if let capture = InputAssistAXTextCapture.captureSelectedText() {
            metrics.shortcutTriggerCount += 1
            startSession(capture: capture, identity: identity, appSettings: appSettings)
            return
        }

        // 取不到不代表用户没选中。Chromium / Electron 应用要先被明确告知
        // 「有人要用辅助功能」才会把树建起来，在那之前这里必然是空的。
        Task { @MainActor [weak self] in
            await self?.retryAfterEnablingChromiumAccessibility(
                identity: identity,
                appSettings: appSettings
            )
        }
    }

    /// 打开目标应用的辅助功能树后重试一次取词。
    ///
    /// 只在第一次取词失败时走这条路——打开别人进程的 AX 树是有开销的，
    /// 不该对每个切换到的应用都默认施加。同一个应用开过一次之后，
    /// 后续按快捷键会直接命中上面的快路径。
    private func retryAfterEnablingChromiumAccessibility(
        identity: InputAssistAppIdentity?,
        appSettings: AppSettings
    ) async {
        guard !isCommitting else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              InputAssistChromiumAccessibility.enableIfNeeded(pid: pid)
        else {
            // 不是 Chromium 应用（属性不支持），或者这个应用已经打开过了。
            // 两种情况重试都没有意义，问题不在这一层。
            toast?.show("请先选择要翻译的文字", style: .warning)
            return
        }

        metrics.chromiumAccessibilityEnabledCount += 1
        log?.info(
            "Input Assist 请求 \(identity?.localizedName ?? "当前应用") 打开辅助功能树后重试取词"
        )
        try? await Task.sleep(
            nanoseconds: InputAssistChromiumAccessibility.settleNanoseconds
        )

        guard !isCommitting else { return }
        // 前台应用在这 200ms 里可能已经换掉了，那这次快照就不该再用。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }

        guard let capture = InputAssistAXTextCapture.captureSelectedText() else {
            log?.warn("Input Assist 打开辅助功能树后仍未读到选中文本")
            toast?.show("已为当前应用开启辅助功能读取，请重新选中一次文字", style: .info)
            return
        }

        metrics.shortcutTriggerCount += 1
        startSession(capture: capture, identity: identity, appSettings: appSettings)
    }

    private func handleAutomaticSelection(_ capture: InputAssistCapture) {
        guard settings.isEnabled, settings.isSelectionAutoShowEnabled else { return }
        guard !isCommitting, !panelController.isVisible, let appSettings else { return }
        let identity = InputAssistAppIdentity.frontmost()
        guard allowsApplication(identity) else { return }

        metrics.selectionAutoShowCount += 1
        startSession(capture: capture, identity: identity, appSettings: appSettings)
    }

    private func isAutomaticSelectionAllowed() -> Bool {
        guard settings.isEnabled, settings.isSelectionAutoShowEnabled else { return false }
        guard !isCommitting, !panelController.isVisible else { return false }
        return allowsApplication(InputAssistAppIdentity.frontmost())
    }

    private func allowsApplication(_ identity: InputAssistAppIdentity?) -> Bool {
        InputAssistAppFilter.allows(
            identity,
            scope: settings.appScope,
            blocklist: settings.blocklist,
            allowlist: settings.allowlist
        )
    }

    private func startSession(
        capture: InputAssistCapture,
        identity: InputAssistAppIdentity?,
        appSettings: AppSettings
    ) {
        cancelInFlightTranslations()
        if panelController.isVisible {
            panelController.dismiss(reason: .replacedByNewSession)
        }

        let rawDetectedSourceLanguage = LanguageDetectionService.shared
            .detectLanguage(in: capture.sourceText)?
            .languageCode
        let detectedSourceLanguage = InputAssistLanguagePolicy.selectionSourceLanguageCode(
            for: capture.sourceText,
            detectedLanguageCode: rawDetectedSourceLanguage
        )
        let visibleTargets = InputAssistLanguagePolicy.visibleTargets(
            settings.targetLanguageCodes,
            sourceLanguageCode: detectedSourceLanguage
        )
        guard !visibleTargets.isEmpty else {
            toast?.show("选中文本已是配置的目标语言", style: .info)
            return
        }

        // 让自动取词知道这段选区已经处理过了。少了这一步，
        // 用快捷键打开的浮层被 Esc 关掉之后会立刻自己弹回来
        // （Esc 的 key-up 会漏到选区监听，而那时它还没记过这段选区）。
        selectionMonitor.registerSelection(capture)

        let session = CandidateSession(
            appBundleIdentifier: identity?.bundleIdentifier,
            capture: capture,
            detectedSourceLanguageCode: detectedSourceLanguage
        )
        let request = CandidateTranslationRequest(
            sourceText: capture.sourceText,
            sourceLanguageCode: detectedSourceLanguage ?? LanguagePreset.auto.code,
            targetLanguageCodes: visibleTargets,
            engineType: appSettings.engineType,
            openAIBaseURL: appSettings.openAIBaseURL,
            openAIModel: appSettings.openAIModel,
            openAIEndpointMode: appSettings.openAIEndpointMode
        )

        currentSession = session
        currentRequest = request

        let commitMode = InputAssistCommitPolicy.mode(
            capability: session.capability,
            allowsEditorPaste: session.allowsEditorPaste,
            hasSourceRange: session.sourceRange != nil,
            hasElementValue: session.elementValueAtCapture != nil
        )

        guard panelController.show(
            languageCodes: visibleTargets,
            sourceText: capture.sourceText,
            anchorRect: capture.anchorRect,
            appearance: appSettings.appearance,
            showsCacheBadge: settings.showsCacheBadge,
            commitMode: commitMode
        ) else {
            log?.error("Input Assist 无法安装候选按键拦截，已取消本次触发")
            currentSession = nil
            currentRequest = nil
            return
        }
        metrics.candidateShowCount += 1

        let sessionID = session.sessionID
        translationTask = candidateService.start(request: request, log: log) {
            [weak self] languageCode, state in
            guard let self, self.currentSession?.sessionID == sessionID else { return }
            if case .translated(_, .cache, _, _) = state {
                self.metrics.cacheHitCount += 1
            }
            self.panelController.updateRow(languageCode: languageCode, state: state)
        }
    }

    private func commitCandidate(at index: Int) {
        guard !isCommitting else { return }
        guard let session = currentSession,
              let translatedText = panelController.translatedText(at: index)
        else {
            return
        }

        isCommitting = true
        panelController.dismiss(reason: .committed)
        cancelInFlightTranslations()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCommitting = false }

            let commitMode = InputAssistCommitPolicy.mode(
                capability: session.capability,
                allowsEditorPaste: session.allowsEditorPaste,
                hasSourceRange: session.sourceRange != nil,
                hasElementValue: session.elementValueAtCapture != nil
            )

            if commitMode == .axReplace {
                let outcome = await InputAssistTextReplaceEngine.replace(
                    session: session,
                    with: translatedText
                )
                if self.handleReplacementOutcome(outcome) {
                    self.clearSessionIfCurrent(session)
                    return
                }
                if session.allowsEditorPaste, outcome.allowsPasteFallback {
                    let pasteOutcome = await InputAssistEditorPasteEngine.replace(
                        session: session,
                        with: translatedText
                    )
                    if self.handleReplacementOutcome(pasteOutcome) {
                        self.clearSessionIfCurrent(session)
                        return
                    }
                }
                // 写出去了但读不回来时，不能说"无法替换"——它可能已经生效了。
                self.copyTranslatedText(
                    translatedText,
                    message: outcome.allowsPasteFallback
                        ? "无法安全替换，译文已复制"
                        : "无法确认替换是否生效，译文已复制",
                    style: .warning,
                    anchorRect: session.anchorRect
                )
            } else if commitMode == .editorPaste {
                let outcome = await InputAssistEditorPasteEngine.replace(
                    session: session,
                    with: translatedText
                )
                if self.handleReplacementOutcome(outcome) {
                    self.clearSessionIfCurrent(session)
                    return
                }
                self.copyTranslatedText(
                    translatedText,
                    message: "编辑器拒绝替换，译文已复制",
                    style: .warning,
                    anchorRect: session.anchorRect
                )
            } else {
                self.copyTranslatedText(
                    translatedText,
                    message: "当前应用不支持原位替换，译文已复制",
                    style: .info,
                    anchorRect: session.anchorRect
                )
            }

            self.clearSessionIfCurrent(session)
        }
    }

    /// 返回 true 表示已经成功完成原位提交。
    private func handleReplacementOutcome(_ outcome: InputAssistReplacementOutcome) -> Bool {
        switch outcome {
        case .replaced(let strategy):
            metrics.candidateCommitCount += 1
            switch strategy {
            case .axDirect: metrics.axReplaceCount += 1
            case .editorPaste: metrics.editorPasteCount += 1
            case .alreadyMatching: metrics.alreadyMatchingCount += 1
            }
            log?.info("Input Assist 原位替换完成（\(strategy.rawValue)）")
            return true
        case .aborted(let reason):
            metrics.safeAbortCount += 1
            log?.warn("Input Assist 放弃原位替换：\(reason.rawValue)")
            return false
        case .failed(let message):
            metrics.safeAbortCount += 1
            log?.warn("Input Assist 原位替换不可用：\(message)")
            return false
        }
    }

    private func copyCandidate(at index: Int) {
        guard let text = panelController.translatedText(at: index),
              let session = currentSession else { return }
        panelController.dismiss(reason: .copied)
        copyTranslatedText(
            text,
            message: "已复制译文",
            style: .success,
            anchorRect: session.anchorRect
        )
    }

    private func copyTranslatedText(
        _ text: String,
        message: String,
        style: ToastCenter.Toast.Style,
        anchorRect: CGRect
    ) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        metrics.candidateCopyCount += 1
        toast?.show(message, style: style)
        let systemImage: String
        switch style {
        case .success: systemImage = "checkmark"
        case .info, .warning, .error: systemImage = "doc.on.doc"
        }
        feedbackPanelController.show(
            message: message,
            systemImage: systemImage,
            anchorRect: anchorRect,
            appearance: appSettings?.appearance
        )
    }

    private func retryCandidate(at index: Int) {
        guard let request = currentRequest,
              let languageCode = panelController.languageCode(at: index),
              let session = currentSession
        else {
            return
        }
        let sessionID = session.sessionID
        let task = candidateService.retry(
            request: request,
            targetLanguageCode: languageCode,
            slotIndex: index,
            log: log
        ) { [weak self] code, state in
            guard let self, self.currentSession?.sessionID == sessionID else { return }
            self.panelController.updateRow(languageCode: code, state: state)
        }
        retryTasks.removeAll { $0.isCancelled }
        retryTasks.append(task)
    }

    private func handleDismiss(reason: CandidateDismissReason) {
        if reason == .escape {
            metrics.dismissByEscapeCount += 1
        }
        guard reason != .committed else { return }
        cancelInFlightTranslations()
        currentSession = nil
        currentRequest = nil
        applePool.cancelAll()
    }

    private func clearSessionIfCurrent(_ session: CandidateSession) {
        guard currentSession?.sessionID == session.sessionID else { return }
        currentSession = nil
        currentRequest = nil
    }

    private func cancelInFlightTranslations() {
        translationTask?.cancel()
        translationTask = nil
        for task in retryTasks {
            task.cancel()
        }
        retryTasks.removeAll()
    }
}
