import AppKit
import ApplicationServices
import Foundation

@MainActor
final class GlobalHotkeyMonitor: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var lastStartFailureMessage: String?

    var onDoubleCopy: ((Int) -> Void)?
    var onDoubleCut: (() -> Void)?

    private var windowMs: Int = 550

    nonisolated(unsafe) private var doubleCutKeyCode: Int = 7

    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var tapThread: Thread?
    nonisolated(unsafe) private var tapRunLoop: CFRunLoop?
    nonisolated private let lifecycleLock = NSLock()
    nonisolated(unsafe) private var startGeneration: UInt = 0

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

        if isRunning || isStarting {
            return
        }

        guard isTrusted else {
            isRunning = false
            lastStartFailureMessage = "缺少辅助功能权限"
            return
        }

        isStarting = true
        lastStartFailureMessage = nil
        let generation = beginStartGeneration()

        lastCmdCDate = nil
        lastCmdXDate = nil

        let thread = Thread { [weak self] in
            guard let self else { return }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if AXIsProcessTrusted(), let tap = monitor.currentEventTap() {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    } else {
                        Task { @MainActor in
                            monitor.stop()
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let isCommandCopy = event.flags.contains(.maskCommand)
                    && event.getIntegerValueField(.keyboardEventKeycode) == 8
                let pasteboardChangeCount = isCommandCopy
                    ? NSPasteboard.general.changeCount
                    : 0
                monitor.handle(
                    event,
                    pasteboardChangeCountBeforeKeyDown: pasteboardChangeCount
                )
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
                    guard self.isStartGenerationCurrent(generation) else { return }
                    self.isStarting = false
                    self.isRunning = false
                    self.lastStartFailureMessage = "无法创建全局快捷键监听"
                }
                return
            }

            guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                Task { @MainActor in
                    guard self.isStartGenerationCurrent(generation) else { return }
                    self.isStarting = false
                    self.isRunning = false
                    self.lastStartFailureMessage = "无法创建全局快捷键运行循环"
                }
                return
            }

            guard let runLoop = CFRunLoopGetCurrent() else {
                CFRunLoopSourceInvalidate(runLoopSource)
                CFMachPortInvalidate(tap)
                Task { @MainActor in
                    guard self.isStartGenerationCurrent(generation) else { return }
                    self.isStarting = false
                    self.isRunning = false
                    self.lastStartFailureMessage = "无法获取全局快捷键运行循环"
                }
                return
            }
            guard self.installLifecycleResources(
                tap: tap,
                source: runLoopSource,
                runLoop: runLoop,
                generation: generation
            ) else {
                CFRunLoopSourceInvalidate(runLoopSource)
                CFMachPortInvalidate(tap)
                return
            }

            CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            Task { @MainActor in
                guard self.isStartGenerationCurrent(generation) else { return }
                self.isStarting = false
                self.isRunning = true
                self.lastStartFailureMessage = nil
            }

            CFRunLoopRun()

            Task { @MainActor in
                guard self.isStartGenerationCurrent(generation) else { return }
                self.stop()
                self.lastStartFailureMessage = "全局快捷键监听已停止"
            }
        }

        tapThread = thread
        thread.start()
    }

    func stop() {
        let resources = invalidateCurrentGeneration()
        isStarting = false

        if let tap = resources.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = resources.source {
            CFRunLoopSourceInvalidate(source)
        }

        if let tap = resources.tap {
            CFMachPortInvalidate(tap)
        }

        if let rl = resources.runLoop {
            CFRunLoopStop(rl)
        }

        tapThread = nil
        lastCmdCDate = nil
        isRunning = false
    }

    nonisolated
    private func beginStartGeneration() -> UInt {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        startGeneration &+= 1
        return startGeneration
    }

    nonisolated
    private func isStartGenerationCurrent(_ generation: UInt) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return generation == startGeneration
    }

    nonisolated
    private func installLifecycleResources(
        tap: CFMachPort,
        source: CFRunLoopSource,
        runLoop: CFRunLoop,
        generation: UInt
    ) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard generation == startGeneration else { return false }
        eventTap = tap
        runLoopSource = source
        tapRunLoop = runLoop
        return true
    }

    nonisolated
    private func currentEventTap() -> CFMachPort? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return eventTap
    }

    nonisolated
    private func invalidateCurrentGeneration() -> (
        tap: CFMachPort?,
        source: CFRunLoopSource?,
        runLoop: CFRunLoop?
    ) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        startGeneration &+= 1
        let resources = (eventTap, runLoopSource, tapRunLoop)
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        return resources
    }

    nonisolated
    private func handle(
        _ event: CGEvent,
        pasteboardChangeCountBeforeKeyDown: Int
    ) {
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
                        onDoubleCopy?(pasteboardChangeCountBeforeKeyDown)
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
