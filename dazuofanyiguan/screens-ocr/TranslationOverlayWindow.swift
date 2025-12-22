import AppKit
import SwiftUI

@MainActor
final class TranslationOverlayWindow: NSWindow {
    init(rect: CGRect, text: String, lines: [VisionOCRService.OCRLine] = []) {
        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        let view = TranslationOverlayView(text: text, lines: lines)
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
