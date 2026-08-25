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
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyUp]
        ) { [weak self] event in
            // 只有**多击**才算"重新划选"的信号。
            //
            // 双击选词是关掉浮层后重新选中同一段文字最常见的手势，
            // 而单击不是：点标题栏、点工具栏、点另一个非文本控件都是单击，
            // 它们不改变焦点元素的选区。按任意左键都清指纹的话，
            // 浮层被点掉之后会立刻自己弹回来——用户点一下窗口边缘，它就回来一次。
            //
            // 这里刻意**不去读 AX 判断选区到底变没变**：那要在全系统每一次左键
            // 按下时都发起 AX 调用，而 AX 调用是会卡住的（见
            // `MiniAssistCapture` 那边关于同步 AX 往返的说明）。
            // 为一个默认关闭的实验开关，把风险加到最高频的事件上不划算。
            let isReselectGesture = event.type == .leftMouseDown && event.clickCount >= 2
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == .leftMouseDown {
                    if isReselectGesture {
                        self.lastFingerprint = nil
                    }
                    return
                }
                self.scheduleCapture()
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

        // 复用 pendingTask 而不是另开一个句柄：stop() / resetSelection() /
        // 应用切换观察者都只认它，重试任务挂在这里才能被一并取消。
        // 这里**不**先 cancel——我们此刻就跑在 pendingTask 里，
        // 取消的是自己；它马上就要结束了，直接接上去即可。
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

    /// 记下这次已经处理过的选区。
    ///
    /// 返回 false 表示和上一次记下的完全相同，调用方应当跳过。
    ///
    /// **快捷键那条路也必须调它。** 否则会出现这个循环：自动显示开着、
    /// 用户在 180ms 自动取词跑起来之前先按了快捷键 → 浮层由快捷键打开，
    /// 而 `lastFingerprint` 还是空的 → 用户按 Esc，浮层在 key-**down** 上关掉
    /// （`CandidateKeyTap` 只拦 keyDown），Esc 的 key-**up** 漏到这里的全局监听 →
    /// 排一次取词 → 选区没变、浮层又已经不可见了 → 浮层立刻自己弹回来。
    ///
    /// 记选区而不是"排除某几个按键"，是因为前者对 Esc、Enter 提交、⌘C 复制
    /// 以及任何其它关闭方式都一致生效，不用去枚举关闭动作。
    @discardableResult
    func registerSelection(_ capture: InputAssistCapture) -> Bool {
        let fingerprint = Fingerprint(
            applicationBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            element: capture.element,
            sourceText: capture.sourceText,
            sourceRange: capture.sourceRange
        )
        if let lastFingerprint, lastFingerprint.matches(fingerprint) {
            return false
        }
        lastFingerprint = fingerprint
        return true
    }

    private func emit(_ capture: InputAssistCapture) {
        guard registerSelection(capture) else { return }
        onSelection?(capture)
    }
}
