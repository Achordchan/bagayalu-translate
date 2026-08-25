import AppKit
import Foundation

enum MiniTranslationRoute: Equatable {
    case translateInBubble
    case openMainWindow
    case showError(String)
}

struct MiniTranslationRouting {
    static func route(
        engineType: TranslationEngineType,
        applePreparationStatus: AppleTranslationPreparationStatus?
    ) -> MiniTranslationRoute {
        guard engineType == .apple else {
            return .translateInBubble
        }

        switch applePreparationStatus {
        case .installed:
            return .translateInBubble
        case .downloadRequired, .none:
            return .openMainWindow
        case .unsupported(let message):
            return .showError(message)
        }
    }
}

struct MiniTranslationRequestTracker {
    private(set) var currentID = UUID()

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    mutating func invalidate() {
        currentID = UUID()
    }

    func accepts(_ id: UUID) -> Bool {
        currentID == id
    }
}

@MainActor
final class MiniTranslationController: ObservableObject {
    private lazy var bubbleModel: MiniTranslationBubbleModel = {
        let model = MiniTranslationBubbleModel()
        model.onDismiss = { [weak self] in
            self?.dismiss(cancelTranslation: true)
        }
        model.onHoverChange = { [weak self] isHovering in
            self?.setHovering(isHovering)
        }
        return model
    }()

    private lazy var panel = MiniTranslationPanel(model: bubbleModel)

    private var requestTracker = MiniTranslationRequestTracker()
    private var requestTask: Task<Void, Never>?
    private var autoDismissTask: Task<Void, Never>?
    private var dismissDeadline: Date?
    private var remainingDismissDuration: TimeInterval?
    private var isHovering = false
    private var anchorPoint = CGPoint.zero

    func translate(
        text: String,
        settings: AppSettings,
        viewModel: TranslatorViewModel,
        appleTranslationCoordinator: AppleTranslationCoordinator,
        windowController: AppWindowController,
        toast: ToastCenter,
        log: LogStore
    ) {
        panel.applyAppearance(settings.appearance)
        bubbleModel.fontSize = AppTextFontSize.sanitized(settings.miniTextFontSize)

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            showStandaloneError("剪贴板中没有可翻译的文字")
            return
        }
        let languagePair = MiniTranslationDirectionResolver.resolve(
            text: trimmedText,
            sourceLanguageCode: settings.sourceLanguageCode,
            targetLanguageCode: settings.targetLanguageCode
        )
        let configuredPair = TranslationLanguagePair(
            sourceLanguageCode: settings.sourceLanguageCode,
            targetLanguageCode: settings.targetLanguageCode
        )
        bubbleModel.showsSmartDirectionNotice = languagePair != configuredPair
        bubbleModel.detectedSourceLanguageName = Self.sourceLanguageName(
            requestedSourceLanguageCode: languagePair.sourceLanguageCode
        )

        requestTask?.cancel()
        autoDismissTask?.cancel()

        let requestID = requestTracker.begin()
        anchorPoint = NSEvent.mouseLocation
        show(.translating)

        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let appleStatus: AppleTranslationPreparationStatus?
            if settings.engineType == .apple {
                appleStatus = await appleTranslationCoordinator.preparationStatus(
                    text: trimmedText,
                    sourceLanguageCode: languagePair.sourceLanguageCode,
                    targetLanguageCode: languagePair.targetLanguageCode
                )
            } else {
                appleStatus = nil
            }

            guard !Task.isCancelled, requestTracker.accepts(requestID) else {
                return
            }

            switch MiniTranslationRouting.route(
                engineType: settings.engineType,
                applePreparationStatus: appleStatus
            ) {
            case .translateInBubble:
                startTranslation(
                    text: trimmedText,
                    requestID: requestID,
                    languagePair: languagePair,
                    settings: settings,
                    appleTranslationCoordinator: appleTranslationCoordinator,
                    windowController: windowController,
                    toast: toast,
                    log: log
                )
            case .openMainWindow:
                restoreMainWindow(
                    text: trimmedText,
                    languagePair: languagePair,
                    viewModel: viewModel,
                    settings: settings,
                    windowController: windowController,
                    toast: toast,
                    log: log
                )
            case .showError(let message):
                show(.error(message))
            }
        }
    }

    func applyAppearance(_ appearance: AppAppearance) {
        panel.applyAppearance(appearance)
    }

    func applyFontSize(_ fontSize: Double) {
        let fontSize = AppTextFontSize.sanitized(fontSize)
        bubbleModel.fontSize = fontSize
        guard panel.isVisible else { return }
        panel.resizeKeepingCurrentPosition(
            contentSize: MiniTranslationLayout.contentSize(
                for: bubbleModel.state,
                fontSize: fontSize,
                showsSmartDirectionNotice: bubbleModel.showsSmartDirectionNotice,
                showsDetectedLanguage: bubbleModel.detectedSourceLanguageName != nil
            )
        )
    }

    func dismiss(cancelTranslation: Bool) {
        requestTask?.cancel()
        requestTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissDeadline = nil
        remainingDismissDuration = nil
        isHovering = false
        requestTracker.invalidate()

        // requestTask 已取消；独立翻译任务会随 Task 取消结束，不触碰主窗口 ViewModel。
        panel.orderOut(nil)
    }

    private func startTranslation(
        text: String,
        requestID: UUID,
        languagePair: TranslationLanguagePair,
        settings: AppSettings,
        appleTranslationCoordinator: AppleTranslationCoordinator,
        windowController: AppWindowController,
        toast: ToastCenter,
        log: LogStore
    ) {
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let translation = try await StandaloneTranslationRunner.translate(
                    text: text,
                    settings: settings,
                    log: log,
                    languagePair: languagePair,
                    appleTranslationCoordinator: appleTranslationCoordinator,
                    onAITextUpdate: { [weak self] partialText in
                        guard let self,
                              !Task.isCancelled,
                              self.requestTracker.accepts(requestID)
                        else {
                            return
                        }
                        self.showStreamingResult(partialText)
                    }
                )
                guard !Task.isCancelled, requestTracker.accepts(requestID) else {
                    return
                }
                // 引擎真正识别出来的语种比请求时的推断更可信，拿它盖掉。
                if let reported = Self.usableLanguageCode(translation.detectedSourceLanguageCode) {
                    bubbleModel.detectedSourceLanguageName =
                        LanguagePreset.displayName(for: reported)
                }
                showCompletedResult(translation.translatedText)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestTracker.accepts(requestID) else {
                    return
                }
                if requiresMainWindow(for: error) {
                    panel.orderOut(nil)
                    requestTracker.invalidate()
                    windowController.showAndActivate()
                    toast.show(error.localizedDescription, style: .error)
                } else {
                    show(.error(error.localizedDescription))
                }
            }
        }
    }

    private func restoreMainWindow(
        text: String,
        languagePair: TranslationLanguagePair,
        viewModel: TranslatorViewModel,
        settings: AppSettings,
        windowController: AppWindowController,
        toast: ToastCenter,
        log: LogStore
    ) {
        requestTracker.invalidate()
        panel.orderOut(nil)
        windowController.showAndActivate()
        viewModel.translateExternalTextNow(
            text,
            settings: settings,
            log: log,
            toast: toast,
            feedbackMode: .standard,
            languagePair: languagePair,
            completion: nil
        )
    }

    private func requiresMainWindow(for error: Error) -> Bool {
        guard let engineError = error as? OpenAICompatibleEngine.EngineError else {
            return false
        }

        switch engineError {
        case .missingAPIKey, .missingModel, .invalidBaseURL(_):
            return true
        case .emptyResponse:
            return false
        }
    }

    /// 页脚显示的原文语种。
    ///
    /// **只显示确实送出去的那个语言。** 源语言是 `auto` 时一律留空、等引擎回报——
    /// 任何在这里做的推断都可能和最终实际使用的语言对不上：
    ///
    /// - 脚本兜底只有 `AppleTranslationCoordinator` 会用，别的引擎收到的就是 auto；
    /// - 就算是 Apple，猜出来的语言对被 `LanguageAvailability` 判成 `.unsupported` 时
    ///   协调器也会**弃用**兜底、改走自动识别。
    ///
    /// 这行页脚的全部价值就在于它是真的。宁可晚一两秒（等
    /// `detectedSourceLanguageCode` 回来）也不能先显示一个可能是错的。
    private static func sourceLanguageName(
        requestedSourceLanguageCode: String
    ) -> String? {
        guard let requested = usableLanguageCode(requestedSourceLanguageCode) else {
            return nil
        }
        return LanguagePreset.displayName(for: requested)
    }

    /// 能拿来显示的语言代码。auto / und / 空都不算。
    private static func usableLanguageCode(_ code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(LanguagePreset.auto.code) != .orderedSame,
              trimmed.caseInsensitiveCompare("und") != .orderedSame
        else {
            return nil
        }
        return trimmed
    }

    private func showStandaloneError(_ message: String) {
        requestTask?.cancel()
        requestTracker.invalidate()
        bubbleModel.showsSmartDirectionNotice = false
        bubbleModel.detectedSourceLanguageName = nil
        anchorPoint = NSEvent.mouseLocation
        show(.error(message))
    }

    private func show(_ state: MiniTranslationBubbleState) {
        bubbleModel.state = state
        panel.present(
            near: anchorPoint,
            contentSize: MiniTranslationLayout.contentSize(
                for: state,
                fontSize: bubbleModel.fontSize,
                showsSmartDirectionNotice: bubbleModel.showsSmartDirectionNotice,
                showsDetectedLanguage: bubbleModel.detectedSourceLanguageName != nil
            )
        )

        switch state {
        case .result, .error:
            scheduleAutoDismiss(after: 8)
        case .translating:
            cancelAutoDismiss()
        }
    }

    private func showStreamingResult(_ text: String) {
        let state = MiniTranslationBubbleState.result(text)
        bubbleModel.state = state
        updateVisiblePanelSize(for: state)
        cancelAutoDismiss()
    }

    private func showCompletedResult(_ text: String) {
        let state = MiniTranslationBubbleState.result(text)
        bubbleModel.state = state
        updateVisiblePanelSize(for: state)
        scheduleAutoDismiss(after: 8)
    }

    private func updateVisiblePanelSize(for state: MiniTranslationBubbleState) {
        let contentSize = MiniTranslationLayout.contentSize(
            for: state,
            fontSize: bubbleModel.fontSize,
            showsSmartDirectionNotice: bubbleModel.showsSmartDirectionNotice,
                showsDetectedLanguage: bubbleModel.detectedSourceLanguageName != nil
        )
        if panel.isVisible {
            if panel.frame.size != contentSize {
                panel.resizeKeepingCurrentPosition(contentSize: contentSize)
            }
        } else {
            panel.present(near: anchorPoint, contentSize: contentSize)
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering

        if hovering {
            if let deadline = dismissDeadline {
                remainingDismissDuration = max(0.1, deadline.timeIntervalSinceNow)
            }
            autoDismissTask?.cancel()
            autoDismissTask = nil
            dismissDeadline = nil
        } else if let remainingDismissDuration {
            scheduleAutoDismiss(after: remainingDismissDuration)
        }
    }

    private func scheduleAutoDismiss(after duration: TimeInterval) {
        autoDismissTask?.cancel()
        remainingDismissDuration = duration

        guard !isHovering else {
            dismissDeadline = nil
            return
        }

        dismissDeadline = Date().addingTimeInterval(duration)
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(cancelTranslation: false)
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissDeadline = nil
        remainingDismissDuration = nil
    }
}
