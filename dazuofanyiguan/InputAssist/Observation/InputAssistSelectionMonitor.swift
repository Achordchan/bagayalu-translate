import AppKit
import ApplicationServices
import Foundation

/// 选区完成后的可选自动触发。
///
/// 只监听 mouse-up / key-up，在用户完成选择后读取一次 AX 选区。
/// 不监听连续输入，不分析输入法组字，不轮询。
@MainActor
final class InputAssistSelectionMonitor {
    var onSelection: ((InputAssistCapture) -> Void)?
    var isSelectionAllowed: (() -> Bool)?

    private struct Fingerprint {
        let applicationBundleIdentifier: String?
        let element: AXUIElement
        let sourceText: String
        let sourceRange: InputAssistTextRange?

        func matches(_ other: Fingerprint) -> Bool {
            applicationBundleIdentifier == other.applicationBundleIdentifier
                && CFEqual(element, other.element)
                && sourceText == other.sourceText
                && sourceRange == other.sourceRange
        }
    }

    private var eventMonitor: Any?
    private var workspaceObserver: (any NSObjectProtocol)?
    private var pendingTask: Task<Void, Never>?
    private var lastFingerprint: Fingerprint?

    static let settleNanoseconds: UInt64 = 180_000_000

    @discardableResult
    func start() -> Bool {
        guard eventMonitor == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyUp]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleCapture()
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pendingTask?.cancel()
                self?.lastFingerprint = nil
            }
        }

        return eventMonitor != nil
    }

    func stop() {
        pendingTask?.cancel()
        pendingTask = nil
        lastFingerprint = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
    }

    func resetSelection() {
        pendingTask?.cancel()
        pendingTask = nil
        lastFingerprint = nil
    }

    private func scheduleCapture() {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.captureIfNeeded()
        }
    }

    private func captureIfNeeded() {
        guard isSelectionAllowed?() ?? true else { return }
        guard let capture = InputAssistAXTextCapture.captureSelectedText() else {
            lastFingerprint = nil
            // Chromium / Electron 在辅助功能树建起来之前一定读不到。
            // 快捷键那条路会处理，自动显示这条也必须处理——否则在这些应用里
            // 自动显示是彻底不工作的，而且用户连一条提示都看不到，
            // 只会觉得"这个开关没用"。
            retryAfterEnablingChromiumAccessibility()
            return
        }
        emit(capture)
    }

    /// 打开目标应用的辅助功能树后重试一次。
    ///
    /// `enableIfNeeded` 每个进程只会返回一次 true，所以每个应用至多多花一次
    /// settle 等待，不会因为用户每点一下没选中的地方就反复重试。
    private func retryAfterEnablingChromiumAccessibility() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              InputAssistChromiumAccessibility.enableIfNeeded(pid: pid)
        else {
            return
        }

        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: InputAssistChromiumAccessibility.settleNanoseconds
            )
            guard !Task.isCancelled, let self else { return }
            guard self.isSelectionAllowed?() ?? true else { return }
            // 等待期间前台应用可能已经切走，那这次快照就不该再用。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return
            }
            guard let capture = InputAssistAXTextCapture.captureSelectedText() else { return }
            self.emit(capture)
        }
    }

    private func emit(_ capture: InputAssistCapture) {
        let fingerprint = Fingerprint(
            applicationBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            element: capture.element,
            sourceText: capture.sourceText,
            sourceRange: capture.sourceRange
        )
        if let lastFingerprint, lastFingerprint.matches(fingerprint) {
            return
        }
        lastFingerprint = fingerprint
        onSelection?(capture)
    }
}
