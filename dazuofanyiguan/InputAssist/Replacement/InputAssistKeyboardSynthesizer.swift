import CoreGraphics
import Foundation

/// 合成键盘事件（⌘V / ⌘A）。
///
/// 所有注入事件都打上 `injectionMarker`，这样自己的按键监听可以立刻认出来跳过。
/// 参考 spendolas/traple 的做法（MIT）：不打标记的话，替换时发出的 ⌘V
/// 会重新进入我们自己的 tap，Phase 3 做自动触发时还会被当成「用户新输入」。
enum InputAssistKeyboardSynthesizer {
    static let injectionMarker: Int64 = 0x4241_4741_5941_4C55

    static let aKeyCode: CGKeyCode = 0
    static let vKeyCode: CGKeyCode = 9

    static func isInjectedByUs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == injectionMarker
    }

    @discardableResult
    static func press(_ keyCode: CGKeyCode, command: Bool = false) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        if command {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        down.setIntegerValueField(.eventSourceUserData, value: injectionMarker)
        up.setIntegerValueField(.eventSourceUserData, value: injectionMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
