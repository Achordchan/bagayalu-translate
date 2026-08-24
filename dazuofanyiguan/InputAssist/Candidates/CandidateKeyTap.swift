import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 候选浮层可见期间的按键拦截。
///
/// **为什么必须用主动 tap（`.defaultTap`）：**
/// PRD §14.1 要求浮层不抢原 App 焦点，但又要能吃掉 ↑ / ↓ / Enter / Esc / ⌘1–6 / ⌘C。
/// `NSEvent.addLocalMonitorForEvents` 只在本 App 是 key window 时才收得到；
/// `addGlobalMonitorForEvents` 收得到但**不能吞**。只有 CGEvent 主动 tap 能做到。
///
/// **和 `GlobalHotkeyMonitor` 的分工：** 那个是常驻监听、永远不吞事件，
/// 所以用 `.listenOnly`（开发日志 2026-08-23 记过原因，那条结论继续有效）。
/// 这里正相反：确实要吞事件，但**只在浮层可见的几秒内存在**，关掉浮层立刻拆。
///
/// 因此有三条硬约束，缺一条就会重蹈「卡顿被系统停用」的覆辙：
/// 1. 生命周期严格绑定浮层：`start` 建、`stop` 立刻 invalidate，不复用不常驻。
/// 2. 回调里只做 keyCode 比对和一次派发，**绝不同步做翻译 / AX 读写 / 任何 IO**。
/// 3. 处理 `.tapDisabledByTimeout` / `.tapDisabledByUserInput`，被停用时重新 enable。
@MainActor
final class CandidateKeyTap {
    /// 回调返回 true 表示这次按键要被吞掉。
    var onKeyEvent: ((InputAssistKeyEvent) -> Bool)?
    var onModifierFlagsChanged: ((_ hasOption: Bool, _ hasCommand: Bool, _ hasControl: Bool, _ hasShift: Bool) -> Void)?

    private(set) var isRunning = false

    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    /// 回调在 tap 线程（这里是主线程 runloop）上同步执行，必须立刻拿到「吞不吞」的答案，
    /// 所以裁决结果直接同步读写这两个字段，不能走 async。
    nonisolated(unsafe) fileprivate var decisionHandler: ((InputAssistKeyEvent) -> Bool)?
    nonisolated(unsafe) fileprivate var flagsHandler: ((Bool, Bool, Bool, Bool) -> Void)?

    func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else { return false }

        decisionHandler = { [weak self] event in
            guard let self, let onKeyEvent = self.onKeyEvent else { return false }
            return onKeyEvent(event)
        }
        flagsHandler = { [weak self] option, command, control, shift in
            self?.onModifierFlagsChanged?(option, command, control, shift)
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<CandidateKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            decisionHandler = nil
            flagsHandler = nil
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            decisionHandler = nil
            flagsHandler = nil
            return false
        }

        // 挂在主 runloop 上：回调本身只做比对和派发，不会阻塞输入。
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning || eventTap != nil else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        decisionHandler = nil
        flagsHandler = nil
        isRunning = false
    }

    deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    nonisolated
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if type == .flagsChanged {
            flagsHandler?(
                flags.contains(.maskAlternate),
                flags.contains(.maskCommand),
                flags.contains(.maskControl),
                flags.contains(.maskShift)
            )
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let decisionHandler else {
            return Unmanaged.passUnretained(event)
        }

        let keyEvent = InputAssistKeyEvent(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            hasCommand: flags.contains(.maskCommand),
            hasOption: flags.contains(.maskAlternate),
            hasControl: flags.contains(.maskControl),
            hasShift: flags.contains(.maskShift)
        )

        return decisionHandler(keyEvent) ? nil : Unmanaged.passUnretained(event)
    }
}
