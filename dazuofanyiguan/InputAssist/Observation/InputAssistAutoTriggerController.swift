import AppKit
import ApplicationServices
import Foundation

/// 一次连续输入的锚点。
struct InputAssistTypingBurst {
    let element: AXUIElement
    /// 这轮输入开始时光标在控件全文里的 UTF-16 偏移。
    let startCaretUTF16Offset: Int
    let appBundleIdentifier: String?

    /// 上一次看到的全文长度和光标位置。
    ///
    /// 用来区分「光标动了是因为刚插入了文字」和「用户自己把光标挪走了」：
    /// 前者全文长度会变，后者不会。见 `InputAssistCaretMovement`。
    var lastValueUTF16Count: Int
    var lastCaretUTF16Offset: Int
}

/// 光标变化的性质判定（纯函数，可单测）。
enum InputAssistCaretMovement: Equatable {
    /// 伴随文本编辑的光标移动——打字本身就会让光标前进，不能当成「用户挪走了光标」。
    case followsEdit
    /// 用户自己移动了光标（方向键、点击、⌘←…）。这轮输入的锚点随即作废。
    case navigation
    /// 什么都没变。
    case unchanged

    static func classify(
        previousValueUTF16Count: Int,
        previousCaretUTF16Offset: Int,
        currentValueUTF16Count: Int,
        currentCaretUTF16Offset: Int
    ) -> InputAssistCaretMovement {
        guard currentValueUTF16Count == previousValueUTF16Count else {
            return .followsEdit
        }
        guard currentCaretUTF16Offset == previousCaretUTF16Offset else {
            return .navigation
        }
        return .unchanged
    }
}

/// 自动触发（PRD §7.1 / §8 / §29）。
///
/// ## 为什么没有 TextDiffTracker
///
/// PRD §32 建议做一个「前后文本 diff」模块。实际写下来发现不需要，而且不做更稳：
///
/// 拼音组字期间，很多 App 会把未上屏的拼音直接写进 `kAXValue`。
/// 用「前后 diff」的话，`nihao`（5 个字符）被 commit 成「你好」（2 个字符）时
/// **光标是往回跳的**，任何基于「只往前增长」的 diff 都会在这里失效，
/// 而放宽成通用 diff 又会把组字过程中的每一次抖动都当成新输入。
///
/// 换个锚点就没这个问题：只记住**这轮输入开始时光标在哪**，
/// 当前的新增内容永远是 `value[burstStart ..< caret]`。
/// 组字期间光标怎么来回跳都不影响这个区间的定义，commit 之后它恰好就是那句中文。
///
/// ## 怎么判断输入法还在组字
///
/// macOS 没有公开 API 能从进程外问出「Apple 拼音现在是不是在组字」
/// （调研过的八个项目全部零覆盖，见 `InputAssist-reuse-notes.md` §7.1）。
/// 这里不去猜状态，只看**新增内容长什么样**：
/// 中文输入法开着、新增的却全是 ASCII 字母 → 那是还没上屏的拼音，等着就行。
/// 一旦出现汉字，说明已经 commit 了。
///
/// ## 为什么不需要额外的键盘监听
///
/// PRD §8.2 担心和原生候选框抢显示，建议加 50–100ms 保护延迟。
/// 这里的时间基准本来就是「最后一次 AX 文本变化」，而原生候选框正是在 commit
/// （也就是那次文本变化）的瞬间关闭的，普通 debounce（200–500ms）已经覆盖了这段间隔，
/// 因此不必再挂一个常驻键盘 tap。
@MainActor
final class InputAssistAutoTriggerController {
    /// 已经确认可以弹候选了。
    var onTrigger: ((InputAssistCapture) -> Void)?
    /// 用户在继续输入，现有浮层应当收起。
    var onInputActivity: (() -> Void)?
    /// 光标移动或者焦点离开了原来的控件——浮层记录的 source range 立刻作废（PRD §15）。
    var onSourceInvalidated: (() -> Void)?

    private let focusObserver = InputAssistFocusObserver()

    private(set) var isRunning = false
    private var burst: InputAssistTypingBurst?
    private var pendingTask: Task<Void, Never>?
    private var suspendedUntil: Date?

    /// 停顿多久算「输入稳定」（PRD §8.1）。
    var debounceMilliseconds: Int = 300
    /// 强标点绕过 debounce 后仍然留的一点保护延迟，避免和原生候选框的收起动画打架（PRD §8.2）。
    var strongPunctuationGuardMilliseconds: Int = 80

    /// 允不允许在当前 App 自动触发，由外部（黑白名单 + 能力等级）决定。
    var isAutoTriggerAllowed: (() -> Bool)?

    /// 允不允许监听我们自己这个进程（只对输入增强测试页开放，见 PRD §48）。
    var isOwnApplicationObservationAllowed: (() -> Bool)? {
        didSet {
            focusObserver.isOwnApplicationObservationAllowed = { [weak self] in
                self?.isOwnApplicationObservationAllowed?() ?? false
            }
        }
    }

    init() {
        focusObserver.onFocusedElementChanged = { [weak self] element in
            self?.handleFocusChanged(to: element)
        }
        focusObserver.onFocusedValueChanged = { [weak self] element in
            self?.handleValueChanged(in: element)
        }
        focusObserver.onSelectionChanged = { [weak self] element in
            self?.handleSelectionChanged(in: element)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        focusObserver.start()
        resetBurst()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cancelPending()
        focusObserver.stop()
        burst = nil
    }

    /// 替换文本期间必须暂停：我们写回去的译文同样会触发 `kAXValueChanged`，
    /// 不挡住的话会被当成「用户又输入了新内容」，转头对着自己的译文再弹一次。
    func suspend(for duration: TimeInterval) {
        cancelPending()
        burst = nil
        suspendedUntil = Date().addingTimeInterval(duration)
    }

    /// 一次触发用掉之后重新起一轮，避免同一段文字反复弹。
    func resetBurst() {
        cancelPending()
        guard let element = focusObserver.focusedElement else {
            burst = nil
            return
        }
        beginBurst(at: element)
    }

    // MARK: - Private

    private var isSuspended: Bool {
        guard let suspendedUntil else { return false }
        if Date() >= suspendedUntil {
            self.suspendedUntil = nil
            return false
        }
        return true
    }

    private func handleFocusChanged(to element: AXUIElement?) {
        cancelPending()
        // 焦点换了控件，之前那份快照指向的东西已经不在眼前了。
        onSourceInvalidated?()
        guard let element else {
            burst = nil
            return
        }
        beginBurst(at: element)
    }

    private func handleSelectionChanged(in element: AXUIElement) {
        // 替换过程中我们自己会移动选区，这时候不能把自己的浮层收掉。
        guard !isSuspended else { return }
        onSourceInvalidated?()

        guard let burst, CFEqual(burst.element, element) else {
            beginBurst(at: element)
            return
        }
        guard let caret = InputAssistAXTextCapture.selectedRange(element)?.location,
              let value = InputAssistAXTextCapture.stringAttribute(
                  element,
                  kAXValueAttribute as String
              )
        else {
            return
        }

        switch InputAssistCaretMovement.classify(
            previousValueUTF16Count: burst.lastValueUTF16Count,
            previousCaretUTF16Offset: burst.lastCaretUTF16Offset,
            currentValueUTF16Count: value.utf16.count,
            currentCaretUTF16Offset: caret
        ) {
        case .unchanged:
            return

        case .followsEdit:
            // 打字本身就会让光标前进，这不算「用户挪走了光标」。
            self.burst?.lastValueUTF16Count = value.utf16.count
            self.burst?.lastCaretUTF16Offset = caret

        case .navigation:
            // 用户自己动了光标——**往前往后都一样**。
            //
            // 只挡「往回删过起点」是不够的：在已有文字中间打完中文再按一下 →，
            // 锚点还停在原处、待触发的任务也还在，等 debounce 到点算出来的
            // source range 就会从锚点一路延伸到光标，把用户原本就有的文字圈进去。
            // 接受那个候选等于替换掉这轮根本没输入过的内容。
            beginBurst(at: element)
        }
    }

    private func handleValueChanged(in element: AXUIElement) {
        guard isRunning, !isSuspended else { return }
        guard isAutoTriggerAllowed?() ?? true else { return }

        // 内容一变，之前那个浮层记录的快照就作废了。
        onInputActivity?()

        guard let burst, CFEqual(burst.element, element) else {
            beginBurst(at: element)
            return
        }
        guard let value = InputAssistAXTextCapture.stringAttribute(element, kAXValueAttribute as String),
              let caret = InputAssistAXTextCapture.selectedRange(element)?.location
        else {
            return
        }
        // 先把「上次看到的样子」更新掉，让 handleSelectionChanged 能正确区分
        // 「光标是被这次编辑带着走的」还是「用户自己挪的」。
        self.burst?.lastValueUTF16Count = value.utf16.count
        self.burst?.lastCaretUTF16Offset = caret

        guard caret > burst.startCaretUTF16Offset else {
            // 删到了起点之前（或光标跳走了），重新起一轮。
            beginBurst(at: element)
            return
        }

        guard let newText = InputAssistAXTextCapture.substring(
            of: value,
            range: InputAssistTextRange(
                location: burst.startCaretUTF16Offset,
                length: caret - burst.startCaretUTF16Offset
            )
        ) else {
            return
        }

        switch InputAssistAutoTriggerPolicy.classify(
            newText: newText,
            isCJKInputSourceActive: InputAssistInputSourceMonitor.isCJKInputSourceActive
        ) {
        case .composing:
            // 拼音还没上屏，什么都别做，也别动锚点。
            cancelPending()

        case .waitForPause:
            schedule(after: debounceMilliseconds, element: element, burst: burst)

        case .triggerImmediately:
            schedule(after: strongPunctuationGuardMilliseconds, element: element, burst: burst)

        case .skip(let reason):
            cancelPending()
            if reason == .tooLong || reason == .looksStructured {
                // 这一轮不可能再变成合适的目标了，直接从当前光标重新起一轮。
                beginBurst(at: element)
            }
        }
    }

    private func beginBurst(at element: AXUIElement) {
        cancelPending()
        guard let caret = InputAssistAXTextCapture.selectedRange(element)?.location else {
            burst = nil
            return
        }
        let valueLength = InputAssistAXTextCapture.stringAttribute(
            element,
            kAXValueAttribute as String
        )?.utf16.count ?? 0
        burst = InputAssistTypingBurst(
            element: element,
            startCaretUTF16Offset: caret,
            appBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            lastValueUTF16Count: valueLength,
            lastCaretUTF16Offset: caret
        )
    }

    private func schedule(after milliseconds: Int, element: AXUIElement, burst: InputAssistTypingBurst) {
        cancelPending()
        let delay = UInt64(max(0, milliseconds)) * 1_000_000
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.fireIfStillValid(element: element, burst: burst)
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// debounce 到点之后再确认一遍：这段时间里用户可能又打了字、换了 App 或挪了光标。
    private func fireIfStillValid(element: AXUIElement, burst: InputAssistTypingBurst) {
        pendingTask = nil
        guard isRunning, !isSuspended else { return }
        guard let currentBurst = self.burst, CFEqual(currentBurst.element, element) else { return }
        guard currentBurst.startCaretUTF16Offset == burst.startCaretUTF16Offset else { return }
        guard let currentFocus = focusObserver.focusedElement, CFEqual(currentFocus, element) else {
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == burst.appBundleIdentifier else {
            return
        }

        guard let capture = InputAssistAXTextCapture.captureForAutoTrigger(
            element: element,
            burstStartUTF16Offset: burst.startCaretUTF16Offset
        ) else {
            return
        }
        onTrigger?(capture)
    }
}
