import AppKit
import ApplicationServices
import Foundation

/// 一次取词的完整快照。
struct InputAssistCapture {
    let element: AXUIElement
    /// 要翻译并最终替换掉的文本。
    let sourceText: String
    /// `sourceText` 在控件全文里的位置（UTF-16）。拿不到就是 nil，
    /// 此时只能走「替换当前选区」而不能按范围替换。
    let sourceRange: InputAssistTextRange?
    /// 控件当前全文，用于 commit 前的二次校验（PRD §44）。
    let elementValue: String?
    /// 送给引擎理解用的上下文，不参与替换（PRD §9.1）。
    let context: String
    let capability: InputAssistSurfaceCapability
    let role: String?
    /// 光标 / 选区在屏幕上的矩形（Cocoa 坐标），用于浮层定位。
    let anchorRect: CGRect
}

/// 跨 App 的 AX 文本读取。
///
/// 实现参考 lglot/translate-kit 的 `ReplaceEngine`（MIT）与
/// everettjf/TypeTide 的 `SelectionCapture` / `PopupPositioner`（MIT），
/// 详见 `InputAssist-reuse-notes.md`。
enum InputAssistAXTextCapture {
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        // 这里必须验类型再转：属性返回非 AXUIElement 时强转会直接崩。
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func selectedRange(_ element: AXUIElement) -> InputAssistTextRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return InputAssistTextRange(location: range.location, length: range.length)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success else {
            return false
        }
        return settable.boolValue
    }

    static func capability(of element: AXUIElement) -> InputAssistSurfaceCapability {
        if isSettable(element, kAXSelectedTextAttribute as String) {
            return .axDirect
        }
        if stringAttribute(element, kAXValueAttribute as String) != nil
            || stringAttribute(element, kAXSelectedTextAttribute as String) != nil {
            return .pasteFallback
        }
        return .unavailable
    }

    /// 光标或选区在屏幕上的位置。三级降级正好对应 PRD §16.1 的 Level 1/2/3。
    static func anchorRect(
        element: AXUIElement,
        range: InputAssistTextRange?
    ) -> CGRect {
        let primaryMaxY = CandidatePanelPositioner.primaryScreenMaxY()

        if let range, let bounds = boundsForRange(element: element, range: range) {
            return CandidatePanelPositioner.cocoaRect(
                fromAXRect: bounds,
                primaryScreenMaxY: primaryMaxY
            )
        }
        if let frame = elementFrame(element) {
            return CandidatePanelPositioner.cocoaRect(
                fromAXRect: frame,
                primaryScreenMaxY: primaryMaxY
            )
        }
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: mouse.y - 4, width: 1, height: 18)
    }

    static func boundsForRange(
        element: AXUIElement,
        range: InputAssistTextRange
    ) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: max(range.length, 1))
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success, let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.width > 0 || rect.height > 0 else {
            return nil
        }
        return rect
    }

    static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
            AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
            ) == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// 手动触发的取词（PRD §26）：有选区就用选区，没有就取 caret 前最近一句。
    ///
    /// 全程只读 AX，不动剪贴板——手动模式下读不到就直接失败，
    /// 比悄悄按一下 ⌘C 去猜用户选了什么安全得多。
    static func captureForManualTrigger() -> InputAssistCapture? {
        guard let element = focusedElement() else { return nil }

        let role = stringAttribute(element, kAXRoleAttribute as String)
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        guard InputAssistSecureInputGuard.allowsAutomation(
            role: role,
            subrole: subrole,
            isSecureEventInputEnabled: InputAssistSecureInputGuard.isSecureEventInputEnabled
        ) else {
            return nil
        }

        let capability = capability(of: element)
        guard capability != .unavailable else { return nil }

        let elementValue = stringAttribute(element, kAXValueAttribute as String)
        let selectedRange = selectedRange(element)

        if let selectedText = stringAttribute(element, kAXSelectedTextAttribute as String),
           !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let range = selectedRange.flatMap { $0.length > 0 ? $0 : nil }
            let context = elementValue.flatMap { value -> String? in
                guard let range else { return nil }
                return InputAssistSentenceBoundary.context(in: value, sourceRange: range)
            } ?? selectedText
            return InputAssistCapture(
                element: element,
                sourceText: selectedText,
                sourceRange: range,
                elementValue: elementValue,
                context: context,
                capability: capability,
                role: role,
                anchorRect: anchorRect(element: element, range: range)
            )
        }

        // 无选区 → caret 前最近一句（PRD §26.2）
        guard let elementValue,
              let caret = selectedRange?.location,
              let sentence = InputAssistSentenceBoundary.currentSentenceRange(
                  in: elementValue,
                  caretUTF16Offset: caret
              ),
              let sourceText = substring(of: elementValue, range: sentence),
              InputAssistSentenceBoundary.looksTranslatable(sourceText)
        else {
            return nil
        }

        return InputAssistCapture(
            element: element,
            sourceText: sourceText,
            sourceRange: sentence,
            elementValue: elementValue,
            context: InputAssistSentenceBoundary.context(in: elementValue, sourceRange: sentence),
            capability: capability,
            role: role,
            anchorRect: anchorRect(element: element, range: sentence)
        )
    }

    /// 按 UTF-16 范围取子串。范围越界或落在字符中间时返回 nil，绝不返回一个「差不多」的结果。
    static func substring(of text: String, range: InputAssistTextRange) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        guard range.upperBound <= text.utf16.count else { return nil }
        guard let start = String.Index(utf16Offset: range.location, in: text)
            .samePosition(in: text),
            let end = String.Index(utf16Offset: range.upperBound, in: text)
                .samePosition(in: text),
            start <= end
        else {
            return nil
        }
        return String(text[start..<end])
    }
}
