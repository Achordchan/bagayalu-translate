import AppKit
import Foundation

@MainActor
final class AppWindowController: NSObject, ObservableObject, NSWindowDelegate {
    nonisolated static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("mainWindow")
    nonisolated static let preferredContentSize = NSSize(width: 980, height: 640)
    nonisolated static let preferredMinSize = NSSize(width: 980, height: 640)

    weak var window: NSWindow?
    private var currentAppearance: AppAppearance = .system
    private var didApplyInitialMetrics = false
    private var pendingMetricsWorkItem: DispatchWorkItem?

    /// 在窗口挂载时绑定身份与外观；尺寸改动延迟到下一轮主线程循环，避免布局递归。
    func bindMainWindow(_ window: NSWindow?, title: String, appearance: AppAppearance) {
        guard let window else { return }

        self.window = window
        window.title = title
        window.identifier = Self.mainWindowIdentifier
        window.isReleasedWhenClosed = false
        window.delegate = self

        applyAppearance(appearance, to: window)

        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.styleMask.remove(.borderless)
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        configureChrome(window)

        scheduleInitialMetricsIfNeeded(for: window)
    }

    private func scheduleInitialMetricsIfNeeded(for window: NSWindow) {
        guard !didApplyInitialMetrics else {
            // 已初始化后只同步 minSize，不强制改当前用户调整后的尺寸。
            if window.minSize != Self.preferredMinSize {
                window.minSize = Self.preferredMinSize
            }
            return
        }

        pendingMetricsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.applyInitialMetrics(to: window)
        }
        pendingMetricsWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func applyInitialMetrics(to window: NSWindow) {
        guard !didApplyInitialMetrics else { return }
        didApplyInitialMetrics = true

        if window.minSize != Self.preferredMinSize {
            window.minSize = Self.preferredMinSize
        }

        let current = window.frame.size
        let preferred = Self.preferredContentSize
        // 仅在系统默认尺寸明显偏离时纠正一次，避免覆盖用户已调整的窗口。
        let needsResize =
            abs(current.width - preferred.width) > 1
            || abs(current.height - preferred.height) > 1
        if needsResize {
            window.setContentSize(preferred)
        }
    }

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
