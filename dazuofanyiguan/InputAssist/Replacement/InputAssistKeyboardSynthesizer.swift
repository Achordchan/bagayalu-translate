import CoreGraphics
import Foundation

enum InputAssistKeyboardSynthesizer {
    static let injectionMarker: Int64 = 0x4241_4741_5941_4C55
    static let vKeyCode: CGKeyCode = 9

    @discardableResult
    static func pressPaste() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: injectionMarker)
        up.setIntegerValueField(.eventSourceUserData, value: injectionMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
