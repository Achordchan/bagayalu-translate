import AppKit
import ApplicationServices
import Foundation

/// 对已知编辑器角色执行受控的选区粘贴替换。
///
/// 只在 App、focused element、选区和原文都与候选创建时一致时发送一次 ⌘V；
/// 剪贴板被用户或管理器改写时不覆盖新内容。
@MainActor
enum InputAssistEditorPasteEngine {
    static let settleNanoseconds: UInt64 = 250_000_000

    static func replace(
        session: CandidateSession,
        with translatedText: String
    ) async -> InputAssistReplacementOutcome {
        guard session.allowsEditorPaste else {
            return .failed(message: "当前控件不是可编辑文本控件")
        }
        guard translatedText != session.sourceText else {
            return .replaced(strategy: .alreadyMatching)
        }
        guard !InputAssistSecureInputGuard.isSecureEventInputEnabled else {
            return .aborted(reason: .secureInputActive)
        }
        guard targetIsUnchanged(session) else {
            return .aborted(reason: .selectionChanged)
        }

        let pasteboard = NSPasteboard.general
        let changeCountBeforeSnapshot = pasteboard.changeCount
        let savedItems = InputAssistPasteboardSnapshot.snapshot(from: pasteboard)
        guard pasteboard.changeCount == changeCountBeforeSnapshot else {
            return .aborted(reason: .clipboardBusy)
        }

        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)
        let translationChangeCount = pasteboard.changeCount

        guard targetIsUnchanged(session) else {
            restoreIfUntouched(
                savedItems,
                expectedChangeCount: translationChangeCount,
                pasteboard: pasteboard
            )
            return .aborted(reason: .selectionChanged)
        }
        guard pasteboard.changeCount == translationChangeCount else {
            // 有人在我们放上译文之后又写了剪贴板。这里既不粘贴也不还原——
            // 还原会把对方刚写进去的内容盖掉。
            return .aborted(reason: .clipboardBusy)
        }
        guard InputAssistKeyboardSynthesizer.pressPaste() else {
            restoreIfUntouched(
                savedItems,
                expectedChangeCount: translationChangeCount,
                pasteboard: pasteboard
            )
            return .failed(message: "无法发送编辑器粘贴事件")
        }

        try? await Task.sleep(nanoseconds: settleNanoseconds)

        // 还原**之前**先看一眼：settle 这 250ms 里有没有人动过剪贴板。
        //
        // `restoreIfUntouched` 会静默地不还原（这是对的），但如果接下来我们要报失败，
        // 协调器就会走复制兜底，把那份新内容清掉。和剪贴板争用那条是同一个矛盾，
        // 只是窗口挪到了 `pressPaste()` 之后。
        let clipboardChangedWhileSettling = pasteboard.changeCount != translationChangeCount
        restoreIfUntouched(
            savedItems,
            expectedChangeCount: translationChangeCount,
            pasteboard: pasteboard
        )

        switch verifyPaste(session, translatedText: translatedText) {
        case .applied:
            // 粘贴确实生效了。这时即使有人动过剪贴板也不该报争用——
            // 替换已经成功，协调器不会再去碰剪贴板。
            return .replaced(strategy: .editorPaste)
        case .rejected:
            return clipboardChangedWhileSettling
                ? .aborted(reason: .clipboardBusy)
                : .failed(message: "编辑器未接受译文替换")
        case .unverifiable:
            return clipboardChangedWhileSettling
                ? .aborted(reason: .clipboardBusy)
                : .aborted(reason: .writeVerificationUnavailable)
        }
    }

    private enum PasteVerification {
        case applied
        case rejected
        /// 读不回来：既证不了也证伪不了。
        case unverifiable
    }

    private static func verifyPaste(
        _ session: CandidateSession,
        translatedText: String
    ) -> PasteVerification {
        if let expectedValue = expectedValueAfterPaste(session, translatedText: translatedText) {
            // 能算出期望值就说明取词那一刻 kAXValue 是读得到的
            // （`expectedValueAfterPaste` 依赖 `elementValueAtCapture`）。
            // 现在读不到，那是瞬时故障或者焦点变了——**不能当成成功**：
            // 目标要是拒绝了粘贴、或者根本没收到，我们会记一次成功，
            // 而且不给复制兜底，用户什么都拿不到。
            guard let currentValue = InputAssistAXTextCapture.stringAttribute(
                session.element,
                kAXValueAttribute as String
            ) else {
                return .unverifiable
            }
            return currentValue == expectedValue ? .applied : .rejected
        }

        // 算不出精确期望值（没有 sourceRange 或没有 elementValue）。
        // `.editorPaste` 这一档**本来就常常**是这种情况——`CommitPolicy` 正是在
        // 缺其中之一时才选它——所以不能因为算不出来就一律判失败，
        // 那会让整条粘贴路径彻底失效。
        //
        // 退到一个便宜的证伪信号：粘贴真的生效的话，选区里不可能还是原文。
        // 只读控件吃掉 ⌘V 之后选区原封不动，正好落在这里。
        // （译文与原文相同的情况在函数开头已按 .alreadyMatching 返回。）
        guard let selectedText = InputAssistAXTextCapture.stringAttribute(
            session.element,
            kAXSelectedTextAttribute as String
        ) else {
            // 连选区都读不到：这个控件什么都不暴露，维持原有的宽松处理，
            // 否则这类应用里粘贴永远算不成功。
            return .applied
        }
        return selectedText == session.sourceText ? .rejected : .applied
    }

    private static func targetIsUnchanged(_ session: CandidateSession) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == session.appBundleIdentifier else {
            return false
        }
        guard let focused = InputAssistAXTextCapture.focusedElement(),
              CFEqual(focused, session.element) else {
            return false
        }
        if let expectedRange = session.selectedRangeAtCapture {
            // 读不回来就当作对不上，不能跳过这条检查。
            //
            // 下面只比对「选中文本是否还等于原文」。同一个控件里出现两处相同文字时
            // （日志、表格、重复的短语），用户把选区挪到另一处，文本比对照样通过，
            // ⌘V 就会打在错误的位置上。位置这一关只能靠 range，读不到就必须放弃。
            guard let currentRange = InputAssistAXTextCapture.selectedRange(focused),
                  currentRange == expectedRange
            else {
                return false
            }
        }
        return InputAssistAXTextCapture.stringAttribute(
            focused,
            kAXSelectedTextAttribute as String
        ) == session.sourceText
    }

    private static func expectedValueAfterPaste(
        _ session: CandidateSession,
        translatedText: String
    ) -> String? {
        guard let value = session.elementValueAtCapture,
              let range = session.sourceRange else {
            return nil
        }
        return InputAssistAXTextCapture.replacingRange(
            in: value,
            range: range,
            with: translatedText
        )
    }

    static func restoreIfUntouched(
        _ items: [NSPasteboardItem],
        expectedChangeCount: Int,
        pasteboard: NSPasteboard
    ) {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        InputAssistPasteboardSnapshot.restore(items, to: pasteboard)
    }
}
