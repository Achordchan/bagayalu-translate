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
    private weak var activeViewModel: TranslatorViewModel?

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

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            showStandaloneError("剪贴板中没有可翻译的文字")
            return
        }

        requestTask?.cancel()
        autoDismissTask?.cancel()
        activeViewModel?.cancelTranslation(clearInput: false)

        let requestID = requestTracker.begin()
        activeViewModel = viewModel
        anchorPoint = NSEvent.mouseLocation
        show(.translating)

        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let appleStatus: AppleTranslationPreparationStatus?
            if settings.engineType == .apple {
                appleStatus = await appleTranslationCoordinator.preparationStatus(
                    text: trimmedText,
                    sourceLanguageCode: settings.sourceLanguageCode,
                    targetLanguageCode: settings.targetLanguageCode
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
                    settings: settings,
                    viewModel: viewModel,
                    windowController: windowController,
                    toast: toast,
                    log: log
                )
            case .openMainWindow:
                restoreMainWindow(
                    text: trimmedText,
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

    func dismiss(cancelTranslation: Bool) {
        requestTask?.cancel()
        requestTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        dismissDeadline = nil
        remainingDismissDuration = nil
        requestTracker.invalidate()

        if cancelTranslation, case .translating = bubbleModel.state {
            activeViewModel?.cancelTranslation(clearInput: false)
        }
        activeViewModel = nil
        panel.orderOut(nil)
    }

    private func startTranslation(
        text: String,
        requestID: UUID,
        settings: AppSettings,
        viewModel: TranslatorViewModel,
        windowController: AppWindowController,
        toast: ToastCenter,
        log: LogStore
    ) {
        viewModel.translateExternalTextNow(
            text,
            settings: settings,
            log: log,
            toast: toast,
            feedbackMode: .external
        ) { [weak self, weak viewModel] result in
            guard let self, requestTracker.accepts(requestID) else {
                return
            }

            switch result {
            case .success(let translation):
                show(.result(translation.translatedText))
            case .failure(let error):
                if requiresMainWindow(for: error) {
                    panel.orderOut(nil)
                    requestTracker.invalidate()
                    activeViewModel = nil
                    windowController.showAndActivate()
                    toast.show(error.localizedDescription, style: .error)
                    viewModel?.lastErrorMessage = error.localizedDescription
                } else {
                    show(.error(error.localizedDescription))
                }
            }
        }
    }

    private func restoreMainWindow(
        text: String,
        viewModel: TranslatorViewModel,
        settings: AppSettings,
        windowController: AppWindowController,
        toast: ToastCenter,
        log: LogStore
    ) {
        requestTracker.invalidate()
        activeViewModel = nil
        panel.orderOut(nil)
        windowController.showAndActivate()
        viewModel.applyExternalText(text, settings: settings, log: log, toast: toast)
    }

    private func requiresMainWindow(for error: Error) -> Bool {
        guard let engineError = error as? OpenAICompatibleEngine.EngineError else {
            return false
        }

        switch engineError {
        case .missingAPIKey, .missingModel, .invalidBaseURL:
            return true
        case .emptyResponse:
            return false
        }
    }

    private func showStandaloneError(_ message: String) {
        requestTask?.cancel()
        activeViewModel?.cancelTranslation(clearInput: false)
        requestTracker.invalidate()
        activeViewModel = nil
        anchorPoint = NSEvent.mouseLocation
        show(.error(message))
    }

    private func show(_ state: MiniTranslationBubbleState) {
        bubbleModel.state = state
        panel.present(
            near: anchorPoint,
            contentSize: MiniTranslationLayout.contentSize(for: state)
        )

        switch state {
        case .result, .error:
            scheduleAutoDismiss(after: 8)
        case .translating:
            cancelAutoDismiss()
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
