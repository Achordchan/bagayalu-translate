import AppKit
import SwiftUI

@MainActor
final class ScreenshotTranslatePanelWindow: NSPanel {
    init(
        rect: CGRect,
        ocrText: String,
        defaultTargetLanguageCode: String,
        onCancel: @escaping () -> Void,
        onTranslate: @escaping (_ source: String, _ target: String, _ phase: ((String) -> Void)?) async -> Result<String, Error>,
        onTranslated: @escaping (String) -> Void
    ) {
        let size = NSSize(width: 440, height: 280)

        // 尽量贴近选区，但避免出屏幕
        var origin = CGPoint(x: rect.minX, y: rect.minY - size.height - 10)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            if origin.y < f.minY { origin.y = min(rect.maxY + 10, f.maxY - size.height) }
            if origin.x < f.minX { origin.x = f.minX + 10 }
            if origin.x + size.width > f.maxX { origin.x = f.maxX - size.width - 10 }
        }

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.titled, .utilityWindow, .closable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        title = "截图翻译"
        isReleasedWhenClosed = false

        let view = ScreenshotTranslatePanelView(
            initialOCRText: ocrText,
            defaultTargetLanguageCode: defaultTargetLanguageCode,
            onCancel: onCancel,
            onTranslate: onTranslate,
            onTranslated: onTranslated
        )

        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
