import AppKit
import SwiftUI

@MainActor
final class SettingsWindowBehavior: NSObject, ObservableObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var didCenterThisShow = false

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.isRestorable = false
        window.delegate = self
        didCenterThisShow = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !didCenterThisShow else { return }
        didCenterThisShow = true
        centerWindowRelativeToMain(window)
    }

    func windowWillClose(_ notification: Notification) {
        didCenterThisShow = false
    }

    private func centerWindowRelativeToMain(_ window: NSWindow) {
        let mainWindow = NSApp.windows.first {
            $0.identifier == AppWindowController.mainWindowIdentifier
        }
        guard let main = mainWindow ?? NSApp.mainWindow ?? NSApp.keyWindow else {
            window.center()
            return
        }

        let mainFrame = main.frame
        var origin = CGPoint(
            x: mainFrame.midX - window.frame.width / 2,
            y: mainFrame.midY - window.frame.height / 2
        )
        if let visibleFrame = main.screen?.visibleFrame ?? window.screen?.visibleFrame {
            origin.x = min(
                max(origin.x, visibleFrame.minX),
                visibleFrame.maxX - window.frame.width
            )
            origin.y = min(
                max(origin.y, visibleFrame.minY),
                visibleFrame.maxY - window.frame.height
            )
        }
        window.setFrameOrigin(origin)
    }
}
