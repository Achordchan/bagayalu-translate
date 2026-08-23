import AppKit
import ApplicationServices
import Foundation

/// 本地统计（PRD §49 / §50）。
///
/// **不记录原文与译文正文**，只记录结构化元信息。
struct InputAssistMetrics: Equatable {
    var manualTriggerCount = 0
    var autoTriggerCount = 0
    var candidateShowCount = 0
    var candidateCommitCount = 0
    var candidateCopyCount = 0
    var cacheHitCount = 0
    var axReplaceCount = 0
    var pasteFallbackCount = 0
    var alreadyMatchingCount = 0
    var safeAbortCount = 0
    var dismissByEscapeCount = 0
    var dismissByTypingCount = 0
}

/// Input Assist 主编排（PRD §31 状态机的 Phase 1 子集）。
///
/// 这一版只做手动触发链路：
/// `快捷键 → AX 取词 → 并行翻译 → 候选浮层 → Enter 安全替换`。
/// 自动触发（AX value diff / 中文 commit 检测）留到 Phase 3，
/// 原因见 PRD §56 与 `InputAssist-reuse-notes.md` §7.1。
@MainActor
final class InputAssistCoordinator: ObservableObject {
    @Published private(set) var metrics = InputAssistMetrics()
    @Published private(set) var lastStatusMessage: String?

    private let settings: InputAssistSettings
    private let hotkeyMonitor = InputAssistHotkeyMonitor()
    private let panelController = CandidatePanelController()
    private let applePool = InputAssistAppleTranslationPool()
    private let autoTrigger = InputAssistAutoTriggerController()
    private lazy var candidateService = CandidateService(applePool: applePool)

    private var appSettings: AppSettings?
    private var log: LogStore?
    private var toast: ToastCenter?

    /// 可注入，方便单测驱动「权限从无到有」这条路径。
    private let isAccessibilityTrustedProvider: () -> Bool
    private var didObserveActivation = false
    /// 输入增强测试页所在的窗口。只有它是 key window 时才允许监听我们自己的进程。
    private weak var testSurfaceWindow: NSWindow?

    private var currentSession: CandidateSession?
    private var currentRequest: CandidateTranslationRequest?
    private var translationTask: Task<Void, Never>?
    /// 单条重试是独立任务，也必须跟着 session 一起取消，
    /// 否则浮层关掉之后它还在继续发请求（OpenAI 那边是要计费的）。
    private var retryTasks: [Task<Void, Never>] = []
    private var isReplacing = false

    var hotkeyStatus: InputAssistHotkeyStatus { hotkeyMonitor.status }
    var isAccessibilityTrusted: Bool { isAccessibilityTrustedProvider() }

    init(
        settings: InputAssistSettings,
        isAccessibilityTrustedProvider: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.settings = settings
        self.isAccessibilityTrustedProvider = isAccessibilityTrustedProvider

        hotkeyMonitor.onTrigger = { [weak self] in
            self?.handleManualTrigger()
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

        autoTrigger.onTrigger = { [weak self] capture in
            self?.handleAutoTrigger(capture)
        }
        autoTrigger.onInputActivity = { [weak self] in
            // 用户还在打字，之前那个浮层记录的快照已经作废。
            self?.panelController.dismiss(reason: .continuedTyping)
        }
        autoTrigger.onSourceInvalidated = { [weak self] in
            self?.panelController.dismiss(reason: .caretMoved)
        }
        autoTrigger.isAutoTriggerAllowed = { [weak self] in
            self?.isAutoTriggerAllowedForFrontmostApplication() ?? false
        }
        autoTrigger.isOwnApplicationObservationAllowed = { [weak self] in
            self?.isTestSurfaceActive ?? false
        }
    }

    /// PRD §48 要求测试页能就地验证自动触发，所以它得把自己的窗口登记进来。
    func registerTestSurfaceWindow(_ window: NSWindow?) {
        testSurfaceWindow = window
    }

    /// 只认「测试窗口正是当前 key window」这一种情况。
    ///
    /// 光看「测试窗口开着」不够——用户可能同时开着设置页在编辑黑名单，
    /// 那里的每一次输入都会被当成待翻译内容。
    var isTestSurfaceActive: Bool {
        guard let testSurfaceWindow else { return false }
        return NSApp.keyWindow === testSurfaceWindow
    }

    /// 由 App 启动 / 设置变化时调用。
    func activate(
        appSettings: AppSettings,
        log: LogStore,
        toast: ToastCenter
    ) {
        self.appSettings = appSettings
        self.log = log
        self.toast = toast
        observeApplicationActivationIfNeeded()
        applyEnabledState()
    }

    /// 用户去系统设置里授权辅助功能，回到 App 时必须重新装配一次。
    ///
    /// 否则会卡在一个很别扭的状态：开关显示「已开启」、权限也给了，
    /// 但快捷键和监听都没注册上——因为开启的那一刻还没有权限，
    /// `applyEnabledState()` 提前返回了，此后再没有人调它。
    /// 只能靠用户自己把开关关了再开，或者重启 App 才能恢复。
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

    /// 只在「开着但因为缺权限没跑起来」这一种情况下重新装配，
    /// 不要每次切回 App 都把快捷键和 AXObserver 拆了重建。
    func reapplyEnabledStateIfPermissionArrived() {
        guard settings.isEnabled else { return }
        guard isAccessibilityTrusted else { return }
        guard !hotkeyMonitor.status.isActive else { return }
        applyEnabledState()
    }

    func applyEnabledState() {
        guard settings.isEnabled else {
            hotkeyMonitor.unregister()
            autoTrigger.stop()
            panelController.dismiss(reason: .featureDisabled)
            applePool.shutdown()
            lastStatusMessage = nil
            return
        }

        guard isAccessibilityTrusted else {
            hotkeyMonitor.unregister()
            autoTrigger.stop()
            lastStatusMessage = "需要辅助功能权限才能使用输入增强"
            return
        }

        hotkeyMonitor.register(settings.shortcut)
        applePool.prepare(slotCount: settings.targetLanguageCodes.count)

        autoTrigger.debounceMilliseconds = settings.triggerDelayMilliseconds
        if settings.isAutoTriggerEnabled {
            autoTrigger.start()
        } else {
            autoTrigger.stop()
        }

        lastStatusMessage = hotkeyMonitor.status.isActive
            ? nil
            : "快捷键 \(settings.shortcut.displayString) 注册失败，可能被其它应用占用"
    }

    func deactivate() {
        hotkeyMonitor.unregister()
        autoTrigger.stop()
        cancelInFlightTranslations()
        panelController.dismiss(reason: .featureDisabled)
        applePool.shutdown()
    }

    // MARK: - 手动触发

    /// 供测试页里的按钮直接调用。
    func triggerManually() {
        handleManualTrigger()
    }

    // MARK: - 自动触发

    private func handleAutoTrigger(_ capture: InputAssistCapture) {
        guard settings.isEnabled, settings.isAutoTriggerEnabled else { return }
        guard let appSettings else { return }
        guard !isReplacing else { return }

        let identity = InputAssistAppIdentity.frontmost()
        guard InputAssistAppFilter.allows(
            identity,
            scope: settings.appScope,
            blocklist: settings.blocklist,
            allowlist: settings.allowlist
        ) else {
            return
        }

        // 到这一步才知道这个输入面的真实能力，用它算出兼容等级再决定放不放行（PRD §46）。
        let level = InputAssistAppCompatibility.level(
            bundleIdentifier: identity?.bundleIdentifier,
            capability: capture.capability,
            hasPreciseCaretBounds: capture.hasPreciseCaretBounds
        )
        guard level.allowsAutoTrigger else {
            log?.info("Input Assist 当前输入面只支持手动触发（等级 \(level.rawValue)）")
            return
        }

        metrics.autoTriggerCount += 1
        startSession(capture: capture, identity: identity, appSettings: appSettings)
    }

    /// 自动触发比手动触发更严格：除了黑白名单，还要求这个 App 的能力等级够得上。
    private func isAutoTriggerAllowedForFrontmostApplication() -> Bool {
        guard settings.isEnabled, settings.isAutoTriggerEnabled else { return false }
        guard !isReplacing else { return false }

        let identity = InputAssistAppIdentity.frontmost()
        guard InputAssistAppFilter.allows(
            identity,
            scope: settings.appScope,
            blocklist: settings.blocklist,
            allowlist: settings.allowlist
        ) else {
            return false
        }
        return !InputAssistAppCompatibility.isManualOnly(identity?.bundleIdentifier)
    }

    // MARK: - 手动触发

    private func handleManualTrigger() {
        guard settings.isEnabled else { return }
        guard let appSettings else { return }

        // 替换正在进行时不能再开一轮：选区沉降和粘贴沉降都是 await，
        // 这中间按快捷键会建出第二个 session，而旧的替换任务收尾时
        // 会把 currentSession 清掉，新浮层就变成一个既收不到结果、也提交不了的空壳。
        guard !isReplacing else {
            log?.info("Input Assist 正在替换中，忽略这次手动触发")
            return
        }

        guard isAccessibilityTrusted else {
            lastStatusMessage = "需要辅助功能权限才能使用输入增强"
            toast?.show("输入增强需要辅助功能权限", style: .warning)
            return
        }

        let identity = InputAssistAppIdentity.frontmost()
        guard InputAssistAppFilter.allows(
            identity,
            scope: settings.appScope,
            blocklist: settings.blocklist,
            allowlist: settings.allowlist
        ) else {
            log?.info("Input Assist 跳过当前应用（黑白名单）")
            return
        }

        guard let capture = InputAssistAXTextCapture.captureForManualTrigger() else {
            log?.info("Input Assist 未能读取到可翻译文本")
            toast?.show("没有读到可翻译的文字", style: .warning)
            return
        }

        metrics.manualTriggerCount += 1
        startSession(capture: capture, identity: identity, appSettings: appSettings)
    }

    private func startSession(
        capture: InputAssistCapture,
        identity: InputAssistAppIdentity?,
        appSettings: AppSettings
    ) {
        // 上一轮还开着就先收掉，避免两个 session 同时指向同一个控件。
        cancelInFlightTranslations()
        if panelController.isVisible {
            panelController.dismiss(reason: .replacedByNewSession)
        }

        let detectedSourceLanguage = LanguageDetectionService.shared
            .detectLanguage(in: capture.sourceText)?
            .languageCode

        // 源语言与目标语言相同的行直接不显示（PRD §10.4）。
        let visibleTargets = InputAssistLanguagePolicy.visibleTargets(
            settings.targetLanguageCodes,
            sourceLanguageCode: detectedSourceLanguage
        )
        guard !visibleTargets.isEmpty else {
            toast?.show("当前文本已经是配置的目标语言", style: .info)
            return
        }

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

        guard panelController.show(
            languageCodes: visibleTargets,
            sourceText: capture.sourceText,
            anchorRect: capture.anchorRect,
            appearance: appSettings.appearance,
            showsCacheBadge: settings.showsCacheBadge
        ) else {
            log?.error("Input Assist 无法安装按键拦截，已取消本次触发")
            currentSession = nil
            currentRequest = nil
            return
        }
        metrics.candidateShowCount += 1

        let sessionID = session.sessionID
        translationTask = candidateService.start(
            request: request,
            log: log
        ) { [weak self] languageCode, state in
            guard let self, self.currentSession?.sessionID == sessionID else { return }
            if case .translated(_, .cache, _, _) = state {
                self.metrics.cacheHitCount += 1
            }
            self.panelController.updateRow(languageCode: languageCode, state: state)
        }
    }

    // MARK: - 候选动作

    private func commitCandidate(at index: Int) {
        guard !isReplacing else { return }
        guard let session = currentSession,
              let translatedText = panelController.translatedText(at: index)
        else {
            return
        }

        isReplacing = true
        // 我们写回去的译文同样会触发 kAXValueChanged。不挡住的话，
        // 自动触发会把它当成「用户又输入了新内容」，转头对着自己的译文再弹一次。
        autoTrigger.suspend(for: 1.2)
        // 先收浮层再替换：浮层的按键 tap 还开着的话，
        // 合成的 ⌘V 虽然带了注入标记，但少一层交互总是更稳。
        panelController.dismiss(reason: .committed)
        cancelInFlightTranslations()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isReplacing = false }

            let outcome = await InputAssistTextReplaceEngine.replace(
                session: session,
                with: translatedText
            )
            // 只清理**自己这一轮**留下的东西。
            // 无条件清空的话，万一期间已经开了新一轮，会把新 session 一起抹掉。
            if self.currentSession?.sessionID == session.sessionID {
                self.currentSession = nil
                self.currentRequest = nil
            }

            // 替换完成后从当前光标重新起一轮，避免刚写进去的译文被算成新输入。
            self.autoTrigger.resetBurst()

            switch outcome {
            case .replaced(let strategy):
                self.metrics.candidateCommitCount += 1
                switch strategy {
                case .axDirect: self.metrics.axReplaceCount += 1
                case .pasteFallback: self.metrics.pasteFallbackCount += 1
                case .alreadyMatching: self.metrics.alreadyMatchingCount += 1
                }
                self.log?.info("Input Assist 替换完成（\(strategy.rawValue)）")

            case .aborted(let reason):
                self.metrics.safeAbortCount += 1
                self.log?.warn("Input Assist 放弃替换：\(reason.rawValue)")
                self.toast?.show(Self.abortMessage(for: reason), style: .warning)

            case .failed(let message):
                self.metrics.safeAbortCount += 1
                self.log?.error("Input Assist 替换失败：\(message)")
                self.toast?.show(message, style: .error)
            }
        }
    }

    private func copyCandidate(at index: Int) {
        guard let text = panelController.translatedText(at: index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        metrics.candidateCopyCount += 1
        panelController.dismiss(reason: .copied)
        toast?.show("已复制译文", style: .success)
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
        switch reason {
        case .escape:
            metrics.dismissByEscapeCount += 1
        case .continuedTyping:
            metrics.dismissByTypingCount += 1
        default:
            break
        }

        guard reason != .committed else { return }
        if reason == .escape {
            // 用户明确关掉了这次候选，同一段文字不该马上再弹一次。
            autoTrigger.resetBurst()
        }
        cancelInFlightTranslations()
        currentSession = nil
        currentRequest = nil
        applePool.cancelAll()
    }

    private func cancelInFlightTranslations() {
        translationTask?.cancel()
        translationTask = nil
        for task in retryTasks {
            task.cancel()
        }
        retryTasks.removeAll()
    }

    private static func abortMessage(
        for reason: InputAssistReplacementSafetyGuard.AbortReason
    ) -> String {
        switch reason {
        case .secureInputActive:
            return "当前是安全输入状态，已跳过替换"
        case .applicationChanged:
            return "应用已切换，已取消替换"
        case .focusLost:
            return "输入框已失去焦点，已取消替换"
        case .focusedElementChanged:
            return "焦点已切换到别的输入框，已取消替换"
        case .selectionChanged:
            return "选区已变化，已取消替换"
        case .sourceTextChanged:
            return "原文已被修改，已取消替换"
        case .sourceRangeUnavailable:
            return "无法确认要替换的范围，已取消替换"
        }
    }
}
