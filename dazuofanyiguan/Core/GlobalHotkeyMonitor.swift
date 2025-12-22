import AppKit
import ApplicationServices
import Foundation

@MainActor
final class GlobalHotkeyMonitor: ObservableObject {
    @Published private(set) var isRunning: Bool = false

    var onDoubleCopy: (() -> Void)?
    var onDoubleCut: (() -> Void)?

    private var windowMs: Int = 550

    nonisolated(unsafe) private var doubleCutKeyCode: Int = 7

    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var tapThread: Thread?
    nonisolated(unsafe) private var tapRunLoop: CFRunLoop?

    private var lastCmdCDate: Date?
    private var lastCmdXDate: Date?

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func start(windowMs: Int, doubleCutKeyCode: Int = 7) {
        self.windowMs = windowMs
        self.doubleCutKeyCode = doubleCutKeyCode

        if isRunning {
            return
        }

        guard isTrusted else {
            isRunning = false
            return
        }

        lastCmdCDate = nil
        lastCmdXDate = nil

        let thread = Thread { [weak self] in
            guard let self else { return }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

            let callback: CGEventTapCallBack = { _, type, event, refcon in
                if type != .keyDown {
                    return Unmanaged.passUnretained(event)
                }

                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(event)
                return Unmanaged.passUnretained(event)
            }

            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: refcon
            ) else {
                Task { @MainActor in
                    self.isRunning = false
                }
                return
            }

            self.eventTap = tap
            self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

            if let runLoopSource = self.runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }

            self.tapRunLoop = CFRunLoopGetCurrent()

            CGEvent.tapEnable(tap: tap, enable: true)

            Task { @MainActor in
                self.isRunning = true
            }

            CFRunLoopRun()
        }

        tapThread = thread
        thread.start()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        lastCmdCDate = nil
        isRunning = false
    }

    nonisolated
    private func handle(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let isCmdDown = flags.contains(.maskCommand)
        let isCKey = keyCode == 8
        let isXKey = keyCode == doubleCutKeyCode

        if !(isCmdDown && (isCKey || isXKey)) { return }

        Task { @MainActor in
            let now = Date()

            if isCKey {
                if let last = lastCmdCDate {
                    let delta = now.timeIntervalSince(last) * 1000
                    if delta <= Double(windowMs) {
                        lastCmdCDate = nil
                        onDoubleCopy?()
                        return
                    }
                }
                lastCmdCDate = now
                return
            }

            if isXKey {
                if let last = lastCmdXDate {
                    let delta = now.timeIntervalSince(last) * 1000
                    if delta <= Double(windowMs) {
                        lastCmdXDate = nil
                        onDoubleCut?()
                        return
                    }
                }
                lastCmdXDate = now
                return
            }
        }
    }
}
