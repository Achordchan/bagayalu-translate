import AppKit
import Foundation

@MainActor
final class AppWindowController: NSObject, ObservableObject, NSWindowDelegate {
    nonisolated static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("mainWindow")

    weak var window: NSWindow?
    private var currentAppearance: AppAppearance = .system

    func applyAppearance(_ appearance: AppAppearance, to window: NSWindow) {
        currentAppearance = appearance
        switch appearance {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func configureChrome(_ window: NSWindow) {
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
    }

    private func resolveMainWindow() -> NSWindow? {
        if let window {
            return window
        }

        if let main = NSApp.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            self.window = main
            return main
        }

        if let visibleKeyable = NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible }) {
            self.window = visibleKeyable
            return visibleKeyable
        }

        if let any = NSApp.windows.first {
            self.window = any
            return any
        }

        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        guard let window = resolveMainWindow() else { return }

        applyAppearance(currentAppearance, to: window)
        configureChrome(window)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureChrome(window)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureChrome(window)
    }

    func performClose() {
        resolveMainWindow()?.performClose(nil)
    }

    func minimize() {
        resolveMainWindow()?.miniaturize(nil)
    }

    func zoom() {
        resolveMainWindow()?.zoom(nil)
    }
}
