import AppKit
import ApplicationServices
import Foundation

enum InputAssistReplacementStrategy: String, Equatable {
    case axDirect
    case pasteFallback
    /// 译文和原文一模一样，目标位置本来就已经是想要的内容，什么都不用做。
    case alreadyMatching
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

    /// 某一刻读到的目标状态 + 对应的裁决。
    private struct Evaluation {
        let element: AXUIElement?
        let value: String?
        let verdict: InputAssistReplacementSafetyGuard.Verdict
    }

    static func replace(
        session: CandidateSession,
        with translatedText: String
    ) async -> InputAssistReplacementOutcome {
        let initial = evaluate(session: session)

        guard let element = initial.element else {
            return .aborted(reason: .focusLost)
        }

        switch initial.verdict {
        case .abort(let reason):
            return .aborted(reason: reason)

        case .replaceRange(let range):
            // 译文和原文完全相同（产品名、型号、引擎原样返回…）时不要动它。
            // 走下去的话：AX 写入「成功」但全文毫无变化，
            // 「有没有生效」的判断只能报失败，接着补一次粘贴——
            // 而此时选区已经塌缩，同样的文字会被插进去第二遍。
            guard translatedText != session.sourceText else {
                return .replaced(strategy: .alreadyMatching)
            }

            // **必须在 selectRange 之前比。**
            //
            // `selectRange` 会把用户当前的选区直接覆盖掉，之后再怎么校验，
            // 验的都只是「我刚设的那个选区还在不在」——用户其实早就把光标挪走了
            // 这件事永远发现不了。
            //
            // 光靠「浮层会在光标移动时自动收起」也不够：有些 App 根本不发
            // AXSelectedTextChanged；关掉自动触发时压根没有人在监听选区；
            // 点击关闭浮层还是异步的，和紧接着的 Enter 之间存在竞态。
            if let selectedRangeAtCapture = session.selectedRangeAtCapture {
                guard let selectionBeforeWrite = InputAssistAXTextCapture.selectedRange(element),
                      selectionBeforeWrite == selectedRangeAtCapture else {
                    return .aborted(reason: .selectionChanged)
                }
            }

            guard selectRange(range, in: element) else {
                // 选不中就绝不往下走：位置没确认时粘贴等于往随机位置写。
                return .failed(message: "无法选中要替换的文本范围")
            }
            try? await Task.sleep(nanoseconds: selectionSettleNanoseconds)

            // 这一觉睡下去的功夫，用户完全可能点到别的输入框或者 ⌘Tab 换了 App。
            // 之前那次校验是在睡之前做的，对现在这一刻不作数——必须重新验一遍。
            // 粘贴兜底尤其危险：合成的 ⌘V 是发给**此刻**的前台 App 的。
            let settled = evaluate(session: session)
            guard let settledElement = settled.element else {
                return .aborted(reason: .focusLost)
            }
            guard CFEqual(settledElement, element) else {
                return .aborted(reason: .focusedElementChanged)
            }
            if case .abort(let reason) = settled.verdict {
                return .aborted(reason: reason)
            }

            // 光是「原文还在原来的位置」不够——那只证明文本没被改过。
            // 用户可能在同一个控件里点了一下，把我们刚设好的选区挪走或者收成了插入点；
            // 这时候写 kAXSelectedText 改的是**新选区**，粘贴则会落在**新光标**处。
            // 所以必须确认这一刻选中的仍然正是我们圈出来的那一段。
            guard let selectionNow = InputAssistAXTextCapture.selectedRange(settledElement),
                  selectionNow == range else {
                return .aborted(reason: .selectionChanged)
            }

            return await writeSelection(
                translatedText,
                in: settledElement,
                valueBeforeWrite: settled.value,
                expectedBundleIdentifier: session.appBundleIdentifier
            )

        case .replaceSelection:
            guard translatedText != session.sourceText else {
                return .replaced(strategy: .alreadyMatching)
            }
            return await writeSelection(
                translatedText,
                in: element,
                valueBeforeWrite: initial.value,
                expectedBundleIdentifier: session.appBundleIdentifier
            )
        }
    }

    private static func evaluate(session: CandidateSession) -> Evaluation {
        let element = InputAssistAXTextCapture.focusedElement()
        let value = element.flatMap {
            InputAssistAXTextCapture.stringAttribute($0, kAXValueAttribute as String)
        }
        let selectedText = element.flatMap {
            InputAssistAXTextCapture.stringAttribute($0, kAXSelectedTextAttribute as String)
        }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        return Evaluation(
            element: element,
            value: value,
            verdict: InputAssistReplacementSafetyGuard.validate(
                expectedSourceText: session.sourceText,
                sourceRange: session.sourceRange,
                currentElementValue: value,
                currentSelectedText: selectedText,
                hasFocusedElement: element != nil,
                isFocusedElementUnchanged: element.map { CFEqual($0, session.element) } ?? false,
                isFrontmostApplicationUnchanged: frontmostBundleID == session.appBundleIdentifier,
                isSecureEventInputEnabled: InputAssistSecureInputGuard.isSecureEventInputEnabled
            )
        )
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
        valueBeforeWrite: String?,
        expectedBundleIdentifier: String?
    ) async -> InputAssistReplacementOutcome {
        // 关键：**只有在能验证结果的前提下才尝试 AX 直写。**
        //
        // 读不到 kAXValue 就没有任何办法判断这次写有没有生效。
        // 如果照写不误，就会掉进最糟的一种情况：写**成功**了、但验证不了，
        // 于是又补一次 ⌘V——此时选区已经塌缩到插入点之后，
        // 译文会被插进去第二遍，把用户的文字弄坏。
        //
        // 所以验证不了就干脆不写，直接走粘贴。这时选区还原封不动地圈着原文，
        // 粘贴正好替换掉它，只会发生一次插入。
        let canVerifyWrite = valueBeforeWrite != nil

        if canVerifyWrite,
           InputAssistAXTextCapture.isSettable(element, kAXSelectedTextAttribute as String) {
            let error = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if error == .success, didWriteTakeEffect(in: element, valueBeforeWrite: valueBeforeWrite) {
                return .replaced(strategy: .axDirect)
            }
            // 走到这里只有两种可能：调用失败，或者调用「成功」但内容没变
            // （Chromium 系会接受 set 然后悄悄忽略它）。两种都没有动过文字，
            // 选区仍然圈着原文，粘贴是安全的。
        }
        return await pasteReplace(text, expectedBundleIdentifier: expectedBundleIdentifier)
    }

    /// `err == .success` 完全不能证明文字真的被改了——必须读回来和写之前比一比。
    ///
    /// 只在 `valueBeforeWrite` 非 nil 时调用；调用方已经保证了这一点。
    ///
    /// 「写之后和写之前不同」这个判据成立的前提是**译文和原文不相同**，
    /// 相同的情况已经在 `replace()` 里提前短路掉了（见 `.alreadyMatching`）。
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
    private static func pasteReplace(
        _ text: String,
        expectedBundleIdentifier: String?
    ) async -> InputAssistReplacementOutcome {
        guard !InputAssistSecureInputGuard.isSecureEventInputEnabled else {
            return .aborted(reason: .secureInputActive)
        }

        // 合成的 ⌘V 是发给**此刻**的前台 App 的，这是整个功能里最危险的一个动作。
        // 调用方虽然刚校验过，但那是几步之前的事——把这条不变式做成自守，
        // 而不是指望每个调用路径都记得先查一遍。
        guard isFrontmostApplication(expectedBundleIdentifier) else {
            return .aborted(reason: .applicationChanged)
        }

        let pasteboard = NSPasteboard.general
        let saved = InputAssistPasteboardSnapshot.snapshot(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // 记下「剪贴板里现在是我们放的东西」这个版本号。
        let ourChangeCount = pasteboard.changeCount

        // 再查一次，而且必须是**紧贴着 press 的最后一件事**。
        //
        // 上面那道 guard 到这里之间隔着一次剪贴板深拷贝——用户剪贴板里要是躺着
        // 一张大图或者 PDF，把每个 item 的每种类型都 materialize 一遍是要花时间的。
        // 那段时间足够用户切走一个 App，⌘V 就贴到别人那里去了。
        guard isFrontmostApplication(expectedBundleIdentifier) else {
            InputAssistPasteboardSnapshot.restore(saved, to: pasteboard)
            return .aborted(reason: .applicationChanged)
        }

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

    static func isFrontmostApplication(_ bundleIdentifier: String?) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
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
