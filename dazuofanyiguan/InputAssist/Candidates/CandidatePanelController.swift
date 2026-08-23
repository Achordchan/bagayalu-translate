import AppKit
import Carbon
import Foundation

/// 浮层关闭的原因，用于本地统计（PRD §49）与调试。
enum CandidateDismissReason: String {
    case escape
    case continuedTyping
    case caretMoved
    case outsideClick
    case applicationSwitched
    case inputSourceChanged
    case committed
    case copied
    case replacedByNewSession
    case featureDisabled
}

/// 候选浮层的生命周期：显示、按键、关闭。
///
/// 刻意不设固定超时（PRD §15）：浮层一直在，直到出现明确的用户行为。
@MainActor
final class CandidatePanelController {
    let model = CandidatePanelModel()

    var onCommit: ((Int) -> Void)?
    var onCopy: ((Int) -> Void)?
    var onRetry: ((Int) -> Void)?
    var onDismiss: ((CandidateDismissReason) -> Void)?

    private lazy var panel: CandidatePanel = {
        let panel = CandidatePanel(model: model)
        return panel
    }()

    private let keyTap = CandidateKeyTap()
    private var mouseMonitor: Any?
    private var workspaceObserver: (any NSObjectProtocol)?
    private var inputSourceObserver: (any NSObjectProtocol)?

    private(set) var isVisible = false

    init() {
        model.onCommitRow = { [weak self] index in
            guard let self else { return }
            guard self.model.state.committableIndices.contains(index) else { return }
            self.onCommit?(index)
        }
        model.onRetryRow = { [weak self] index in
            self?.onRetry?(index)
        }

        keyTap.onKeyEvent = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }
        keyTap.onModifierFlagsChanged = { [weak self] option, command, control, shift in
            guard let self else { return }
            let shows = InputAssistKeyRouter.showsDebugOverlay(
                hasOption: option,
                hasCommand: command,
                hasControl: control,
                hasShift: shift
            )
            guard self.model.showsDebugInfo != shows else { return }
            self.model.showsDebugInfo = shows
            self.resizeToFitContent()
        }
    }

    /// 返回 false 表示按键拦截没能装上（多半是辅助功能权限掉了），调用方应当放弃这次触发。
    @discardableResult
    func show(
        languageCodes: [String],
        anchorRect: CGRect,
        appearance: AppAppearance,
        showsCacheBadge: Bool
    ) -> Bool {
        model.state = CandidateListState(languageCodes: languageCodes)
        model.showsDebugInfo = false
        model.showsCacheBadge = showsCacheBadge

        panel.applyAppearance(appearance)
        panel.present(
            anchorRect: anchorRect,
            contentSize: CandidatePanelLayout.panelSize(
                rows: model.state.rows,
                selectedIndex: model.state.selectedIndex,
                showsDebugInfo: false
            )
        )
        isVisible = true

        guard keyTap.start() else {
            dismiss(reason: .featureDisabled)
            return false
        }
        installDismissMonitors()
        return true
    }

    func updateRow(languageCode: String, state: CandidateRowState) {
        guard isVisible else { return }
        guard model.state.update(languageCode: languageCode, state: state) else { return }
        resizeToFitContent()
    }

    func dismiss(reason: CandidateDismissReason) {
        guard isVisible || keyTap.isRunning else { return }
        isVisible = false
        keyTap.stop()
        removeDismissMonitors()
        panel.orderOut(nil)
        onDismiss?(reason)
    }

    var selectedIndex: Int { model.state.selectedIndex }

    var selectedTranslatedText: String? {
        model.state.selectedRow?.translatedText
    }

    func translatedText(at index: Int) -> String? {
        guard model.state.rows.indices.contains(index) else { return nil }
        return model.state.rows[index].translatedText
    }

    func languageCode(at index: Int) -> String? {
        guard model.state.rows.indices.contains(index) else { return nil }
        return model.state.rows[index].languageCode
    }

    // MARK: - Private

    /// 高亮行可以展开到 4 行，所以选中位置变化会改变高度；
    /// 但行数在浮层出现时就定死了，不会随翻译陆续返回而一条条长出来（PRD §12.2）。
    private func resizeToFitContent() {
        guard isVisible else { return }
        let size = CandidatePanelLayout.panelSize(
            rows: model.state.rows,
            selectedIndex: model.state.selectedIndex,
            showsDebugInfo: model.showsDebugInfo
        )
        guard panel.frame.size != size else { return }
        // 顶边固定，向下生长，避免浮层在光标上方来回跳。
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(topLeft)
    }

    private func handleKeyEvent(_ event: InputAssistKeyEvent) -> Bool {
        guard isVisible else { return false }

        guard let decision = InputAssistKeyRouter.decide(
            for: event,
            candidateCount: model.state.count,
            selectedIndex: model.state.selectedIndex,
            committableIndices: model.state.committableIndices
        ) else {
            return false
        }

        switch decision.action {
        case .moveUp:
            if model.state.moveSelection(by: -1) { resizeToFitContent() }
        case .moveDown:
            if model.state.moveSelection(by: 1) { resizeToFitContent() }
        case .commit:
            onCommit?(model.state.selectedIndex)
        case .commitIndex(let index):
            if model.state.select(index: index) { resizeToFitContent() }
            onCommit?(index)
        case .copySelection:
            onCopy?(model.state.selectedIndex)
        case .dismiss:
            dismiss(reason: .escape)
        case .dismissPassingEventThrough:
            dismiss(reason: dismissReason(for: event))
        }

        return decision.swallowsEvent
    }

    private func dismissReason(for event: InputAssistKeyEvent) -> CandidateDismissReason {
        switch event.keyCode {
        case InputAssistKeyRouter.leftArrow, InputAssistKeyRouter.rightArrow:
            return .caretMoved
        default:
            return .continuedTyping
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss(reason: .outsideClick)
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(reason: .applicationSwitched)
            }
        }

        inputSourceObserver = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(reason: .inputSourceChanged)
            }
        }
    }

    private func removeDismissMonitors() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil

        if let inputSourceObserver {
            DistributedNotificationCenter.default.removeObserver(inputSourceObserver)
        }
        inputSourceObserver = nil
    }
}
