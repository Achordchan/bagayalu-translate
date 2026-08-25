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
            return .failed(message: "剪贴板正在被其它应用修改")
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
            return .failed(message: "剪贴板已被其它应用改写")
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
        restoreIfUntouched(
            savedItems,
            expectedChangeCount: translationChangeCount,
            pasteboard: pasteboard
        )

        if let expectedValue = expectedValueAfterPaste(session, translatedText: translatedText) {
            if let currentValue = InputAssistAXTextCapture.stringAttribute(
                session.element,
                kAXValueAttribute as String
            ), currentValue != expectedValue {
                return .failed(message: "编辑器未接受译文替换")
            }
            return .replaced(strategy: .editorPaste)
        }

        // 算不出精确期望值（没有 sourceRange 或没有 elementValue）。
        // `.editorPaste` 这一档**本来就常常**是这种情况——`CommitPolicy` 正是在
        // 缺其中之一时才选它——所以不能因为算不出来就一律判失败，
        // 那会让整条粘贴路径彻底失效。
        //
        // 但还有一个便宜的证伪信号：粘贴真的生效的话，选区里不可能还是原文。
        // 只读控件吃掉 ⌘V 之后选区原封不动，正好落在这里。
        // （译文与原文相同的情况在函数开头已经按 .alreadyMatching 返回了。）
        if let selectedText = InputAssistAXTextCapture.stringAttribute(
            session.element,
            kAXSelectedTextAttribute as String
        ), selectedText == session.sourceText {
            return .failed(message: "编辑器未接受译文替换")
        }
        return .replaced(strategy: .editorPaste)
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
