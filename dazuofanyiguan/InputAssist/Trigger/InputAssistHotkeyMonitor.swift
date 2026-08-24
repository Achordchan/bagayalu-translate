import AppKit
import Carbon
import Foundation

enum InputAssistHotkeyStatus: Equatable {
    case inactive
    case registered
    case unavailable(OSStatus)

    var message: String {
        switch self {
        case .inactive: return "未启用"
        case .registered: return "已注册"
        case .unavailable: return "快捷键被其它应用占用"
        }
    }

    var isActive: Bool { self == .registered }
}

/// 手动触发快捷键（PRD §7.2 / §26）。
///
/// 用 Carbon `RegisterEventHotKey` 而不是 CGEvent tap：
/// 系统层面独占这个组合、自动吞掉按键（⌥Space 在多数 App 里本来会插入不换行空格，
/// 必须吞），而且不会像常驻 tap 那样把本进程插进全系统键盘输入的必经之路上。
///
/// 结构参考 everettjf/TypeTide `GlobalShortcutCenter`（MIT）。
@MainActor
final class InputAssistHotkeyMonitor: ObservableObject {
    @Published private(set) var status: InputAssistHotkeyStatus = .inactive

    var onTrigger: (() -> Void)?

    private static let hotkeyID: UInt32 = 0x4941_0001
    private static let signature: OSType = 0x4241_4741 // 'BAGA'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var lastFiredUptimeNanoseconds: UInt64 = 0

    /// Carbon 对长按会重复投递 pressed 事件，短窗口内合并掉。
    private let repeatSuppressionNanoseconds: UInt64 = 300_000_000

    func register(_ shortcut: InputAssistShortcut) {
        unregister()
        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: Self.hotkeyID)
        let result = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        if result == noErr, let reference {
            hotKeyRef = reference
            status = .registered
        } else {
            status = .unavailable(result)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        status = .inactive
    }

    fileprivate func handleHotkeyPressed() {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastFiredUptimeNanoseconds > 0,
           now >= lastFiredUptimeNanoseconds,
           now - lastFiredUptimeNanoseconds < repeatSuppressionNanoseconds {
            return
        }
        lastFiredUptimeNanoseconds = now
        onTrigger?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard identifier.id == InputAssistHotkeyMonitor.hotkeyID else { return noErr }
                let monitor = Unmanaged<InputAssistHotkeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    monitor.handleHotkeyPressed()
                }
                return noErr
            },
            1,
            &specification,
            context,
            &eventHandler
        )
    }
}
