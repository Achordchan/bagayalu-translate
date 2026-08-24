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

        if let expectedValue = expectedValueAfterPaste(session, translatedText: translatedText),
           let currentValue = InputAssistAXTextCapture.stringAttribute(
               session.element,
               kAXValueAttribute as String
           ),
           currentValue != expectedValue {
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
        if let expectedRange = session.selectedRangeAtCapture,
           let currentRange = InputAssistAXTextCapture.selectedRange(focused),
           currentRange != expectedRange {
            return false
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
