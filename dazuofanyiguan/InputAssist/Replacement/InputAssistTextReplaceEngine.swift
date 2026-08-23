import AppKit
import ApplicationServices
import Foundation

enum InputAssistReplacementStrategy: String, Equatable {
    case axDirect
    case pasteFallback
}

enum InputAssistReplacementOutcome: Equatable {
    case replaced(strategy: InputAssistReplacementStrategy)
    case aborted(reason: InputAssistReplacementSafetyGuard.AbortReason)
    case failed(message: String)
}

/// 文本替换（PRD §27 / §28）。
///
/// 策略是能力驱动的：AX 能精确写就精确写，不能就退到合成粘贴，
/// 两条都不可靠时**放弃**——
/// > A missed translation is better than deleting or replacing the wrong text.
///
/// AX 读写部分参考 lglot/translate-kit `ReplaceEngine`（MIT），
/// 剪贴板快照参考 everettjf/TypeTide（MIT）。
@MainActor
enum InputAssistTextReplaceEngine {
    /// 粘贴后要等目标 App 把剪贴板读走再恢复，恢复太早会把待粘贴内容覆盖掉。
    /// TypeTide 用 150ms、translate-kit 用 300ms，这里取中间值。
    static let pasteSettleNanoseconds: UInt64 = 250_000_000
    static let selectionSettleNanoseconds: UInt64 = 40_000_000

    static func replace(
        session: CandidateSession,
        with translatedText: String
    ) async -> InputAssistReplacementOutcome {
        let currentElement = InputAssistAXTextCapture.focusedElement()
        let currentValue = currentElement.flatMap {
            InputAssistAXTextCapture.stringAttribute($0, kAXValueAttribute as String)
        }
        let currentSelectedText = currentElement.flatMap {
            InputAssistAXTextCapture.stringAttribute($0, kAXSelectedTextAttribute as String)
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: session.sourceText,
            sourceRange: session.sourceRange,
            currentElementValue: currentValue,
            currentSelectedText: currentSelectedText,
            hasFocusedElement: currentElement != nil,
            isFrontmostApplicationUnchanged: frontmostBundleID == session.appBundleIdentifier,
            isSecureEventInputEnabled: InputAssistSecureInputGuard.isSecureEventInputEnabled
        )

        guard let element = currentElement else {
            return .aborted(reason: .focusLost)
        }

        switch verdict {
        case .abort(let reason):
            return .aborted(reason: reason)

        case .replaceRange(let range):
            guard selectRange(range, in: element) else {
                // 选不中就绝不往下走：位置没确认时粘贴等于往随机位置写。
                return .failed(message: "无法选中要替换的文本范围")
            }
            try? await Task.sleep(nanoseconds: selectionSettleNanoseconds)
            return await writeSelection(
                translatedText,
                in: element,
                valueBeforeWrite: currentValue
            )

        case .replaceSelection:
            return await writeSelection(
                translatedText,
                in: element,
                valueBeforeWrite: currentValue
            )
        }
    }

    // MARK: - Private

    private static func selectRange(
        _ range: InputAssistTextRange,
        in element: AXUIElement
    ) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        guard error == .success else { return false }

        // 有的 App 接受这次 set 却不真的移动选区，读回来确认一下。
        guard let applied = InputAssistAXTextCapture.selectedRange(element) else { return false }
        return applied == range
    }

    private static func writeSelection(
        _ text: String,
        in element: AXUIElement,
        valueBeforeWrite: String?
    ) async -> InputAssistReplacementOutcome {
        if InputAssistAXTextCapture.isSettable(element, kAXSelectedTextAttribute as String) {
            let error = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if error == .success, didWriteTakeEffect(in: element, valueBeforeWrite: valueBeforeWrite) {
                return .replaced(strategy: .axDirect)
            }
        }
        return await pasteReplace(text)
    }

    /// Chromium 系会「接受」`AXUIElementSetAttributeValue` 然后悄悄忽略它，
    /// `err == .success` 完全不能证明文字真的被改了——必须读回来和写之前比一比。
    ///
    /// 读不到 kAXValue 时（有些富文本控件不暴露）无法证伪，只能保守地当作没生效，
    /// 转去走粘贴兜底：多贴一次的代价，远小于用户以为翻译了、实际什么都没发生。
    private static func didWriteTakeEffect(
        in element: AXUIElement,
        valueBeforeWrite: String?
    ) -> Bool {
        guard let valueBeforeWrite else { return false }
        guard let valueAfterWrite = InputAssistAXTextCapture.stringAttribute(
            element,
            kAXValueAttribute as String
        ) else {
            return false
        }
        return valueAfterWrite != valueBeforeWrite
    }

    /// 合成 ⌘V 替换当前选区。
    ///
    /// 走粘贴而不是逐字重打，是为了尽量落进宿主 App 自己的 Undo 栈（PRD §28.1）。
    private static func pasteReplace(_ text: String) async -> InputAssistReplacementOutcome {
        guard !InputAssistSecureInputGuard.isSecureEventInputEnabled else {
            return .aborted(reason: .secureInputActive)
        }

        let pasteboard = NSPasteboard.general
        let saved = InputAssistPasteboardSnapshot.snapshot(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // 记下「剪贴板里现在是我们放的东西」这个版本号。
        let ourChangeCount = pasteboard.changeCount

        guard InputAssistKeyboardSynthesizer.press(
            InputAssistKeyboardSynthesizer.vKeyCode,
            command: true
        ) else {
            restoreIfUntouched(saved, expectedChangeCount: ourChangeCount, on: pasteboard)
            return .failed(message: "无法合成粘贴事件")
        }

        try? await Task.sleep(nanoseconds: pasteSettleNanoseconds)
        restoreIfUntouched(saved, expectedChangeCount: ourChangeCount, on: pasteboard)
        return .replaced(strategy: .pasteFallback)
    }

    /// 只在剪贴板里还是我们放进去的那份译文时才还原。
    ///
    /// 等待粘贴落地的这 250ms 里用户完全可能复制了别的东西（剪贴板管理器也会写）。
    /// 无条件还原会把用户刚复制的内容悄悄换回旧快照——
    /// 替换成功了、剪贴板却被毁了，比不还原糟得多。
    static func restoreIfUntouched(
        _ items: [NSPasteboardItem],
        expectedChangeCount: Int,
        on pasteboard: NSPasteboard
    ) {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        InputAssistPasteboardSnapshot.restore(items, to: pasteboard)
    }
}
