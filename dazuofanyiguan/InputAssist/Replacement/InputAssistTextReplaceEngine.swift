import AppKit
import ApplicationServices
import Foundation

enum InputAssistReplacementStrategy: String, Equatable {
    case axDirect
    case editorPaste
    /// 译文与原文一样，不执行写入。
    case alreadyMatching
}

enum InputAssistReplacementOutcome: Equatable {
    case replaced(strategy: InputAssistReplacementStrategy)
    case aborted(reason: InputAssistReplacementSafetyGuard.AbortReason)
    case failed(message: String)

    /// 这次尝试之后，还能不能安全地再走一次粘贴兜底。
    ///
    /// 唯一不能的是 `.writeVerificationUnavailable`：AX 写调用**已经发出去了**，
    /// 但读不回结果，无法证明到底生效没有。此时再合成一次 ⌘V，
    /// 万一那次写其实成功了，译文就会被插入两遍——用户的文本被改坏，
    /// 而且是在他明确要求"安全替换"的路径上。
    ///
    /// 其余情况要么根本没动手写（selectRange 失败、算不出 expected、
    /// 各种 abort），要么已经读回来证实没生效（`.failed` 那条），兜底是安全的。
    var allowsPasteFallback: Bool {
        guard case .aborted(let reason) = self else { return true }
        return reason != .writeVerificationUnavailable
    }
}

/// 只执行可精确验证的 AX 原位替换。
///
/// 无法读回完整结果、选区已变化或目标应用拒绝写入时，直接失败。
/// 复制译文由 Coordinator 明确执行，本引擎不合成 ⌘V。
@MainActor
enum InputAssistTextReplaceEngine {
    static let selectionSettleNanoseconds: UInt64 = 40_000_000
    static let writeVerificationRetryNanoseconds: UInt64 = 30_000_000

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
        case .replaceSelection:
            // 没有全文范围时算不出精确 expected-after，不执行写入。
            return .failed(message: "无法确认选中文本在输入框中的精确位置")
        case .replaceRange(let range):
            guard translatedText != session.sourceText else {
                return .replaced(strategy: .alreadyMatching)
            }

            if let selectedRangeAtCapture = session.selectedRangeAtCapture {
                guard InputAssistAXTextCapture.selectedRange(element) == selectedRangeAtCapture else {
                    return .aborted(reason: .selectionChanged)
                }
            }

            guard selectRange(range, in: element) else {
                return .failed(message: "无法选中要替换的文本范围")
            }
            try? await Task.sleep(nanoseconds: selectionSettleNanoseconds)

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
            guard InputAssistAXTextCapture.selectedRange(settledElement) == range else {
                return .aborted(reason: .selectionChanged)
            }

            guard let valueBeforeWrite = settled.value,
                  let expectedValueAfterWrite = InputAssistAXTextCapture.replacingRange(
                      in: valueBeforeWrite,
                      range: range,
                      with: translatedText
                  )
            else {
                return .failed(message: "无法计算替换后的精确文本")
            }
            guard InputAssistAXTextCapture.isSettable(
                settledElement,
                kAXSelectedTextAttribute as String
            ) else {
                return .failed(message: "当前应用不支持精确原位替换")
            }
            if let reason = invalidTargetReason(
                element: settledElement,
                expectedSelectedRange: range,
                expectedSelectedText: session.sourceText,
                expectedBundleIdentifier: session.appBundleIdentifier
            ) {
                return .aborted(reason: reason)
            }

            // 返回码不能证明是否已写入，最终只信读回的精确全文。
            _ = AXUIElementSetAttributeValue(
                settledElement,
                kAXSelectedTextAttribute as CFString,
                translatedText as CFString
            )

            switch await verifyWrite(
                in: settledElement,
                valueBeforeWrite: valueBeforeWrite,
                expectedValueAfterWrite: expectedValueAfterWrite
            ) {
            case .applied:
                return .replaced(strategy: .axDirect)
            case .didNotApply:
                return .failed(message: "当前应用拒绝了原位替换")
            case .unverifiable:
                return .aborted(reason: .writeVerificationUnavailable)
            }
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
                isFrontmostApplicationUnchanged:
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        == session.appBundleIdentifier,
                isSecureEventInputEnabled: InputAssistSecureInputGuard.isSecureEventInputEnabled
            )
        )
    }

    private static func selectRange(
        _ range: InputAssistTextRange,
        in element: AXUIElement
    ) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success else {
            return false
        }
        return InputAssistAXTextCapture.selectedRange(element) == range
    }

    enum WriteVerification: Equatable {
        case applied
        case didNotApply
        case unverifiable

        static func classify(
            valueAfterWrite: String?,
            valueBeforeWrite: String,
            expectedValueAfterWrite: String
        ) -> WriteVerification {
            guard let valueAfterWrite else { return .unverifiable }
            if valueAfterWrite == expectedValueAfterWrite { return .applied }
            if valueAfterWrite == valueBeforeWrite { return .didNotApply }
            return .unverifiable
        }

        static func resolve(
            first: WriteVerification,
            second: WriteVerification
        ) -> WriteVerification {
            if first == .applied || second == .applied { return .applied }
            if first == .didNotApply, second == .didNotApply { return .didNotApply }
            return .unverifiable
        }
    }

    private static func verifyWrite(
        in element: AXUIElement,
        valueBeforeWrite: String,
        expectedValueAfterWrite: String
    ) async -> WriteVerification {
        func read() -> WriteVerification {
            WriteVerification.classify(
                valueAfterWrite: InputAssistAXTextCapture.stringAttribute(
                    element,
                    kAXValueAttribute as String
                ),
                valueBeforeWrite: valueBeforeWrite,
                expectedValueAfterWrite: expectedValueAfterWrite
            )
        }

        let first = read()
        if first == .applied { return .applied }
        try? await Task.sleep(nanoseconds: writeVerificationRetryNanoseconds)
        return WriteVerification.resolve(first: first, second: read())
    }

    static func isFrontmostApplication(_ bundleIdentifier: String?) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    static func invalidTargetReason(
        element: AXUIElement,
        expectedSelectedRange: InputAssistTextRange?,
        expectedSelectedText: String?,
        expectedBundleIdentifier: String?
    ) -> InputAssistReplacementSafetyGuard.AbortReason? {
        guard isFrontmostApplication(expectedBundleIdentifier) else {
            return .applicationChanged
        }
        guard let focusedNow = InputAssistAXTextCapture.focusedElement(),
              CFEqual(focusedNow, element) else {
            return .focusedElementChanged
        }
        guard isSelectionUnchanged(
            in: element,
            expectedSelectedRange: expectedSelectedRange,
            expectedSelectedText: expectedSelectedText
        ) else {
            return .selectionChanged
        }
        return nil
    }

    static func isSelectionUnchanged(
        in element: AXUIElement,
        expectedSelectedRange: InputAssistTextRange?,
        expectedSelectedText: String?
    ) -> Bool {
        if let expectedSelectedRange {
            guard InputAssistAXTextCapture.selectedRange(element) == expectedSelectedRange else {
                return false
            }
            if let expectedSelectedText {
                return InputAssistAXTextCapture.stringAttribute(
                    element,
                    kAXSelectedTextAttribute as String
                ) == expectedSelectedText
            }
            return true
        }
        if let expectedSelectedText {
            return InputAssistAXTextCapture.stringAttribute(
                element,
                kAXSelectedTextAttribute as String
            ) == expectedSelectedText
        }
        return false
    }
}
