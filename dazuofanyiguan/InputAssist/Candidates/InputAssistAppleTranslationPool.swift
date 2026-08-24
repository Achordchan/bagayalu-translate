import AppKit
import SwiftUI

/// Apple 本地翻译的并行槽位。
///
/// **为什么需要一个池子：** `AppleTranslationCoordinator` 同一时刻只能处理一个请求
/// （单个 `continuation` + `pendingRequest`，新请求进来会把旧的 cancel 掉），
/// 而且它依赖 SwiftUI `.translationTask` 把 session 送进来。
/// PRD §18 要求所有目标语言并行翻译，用一个 coordinator 做不到——
/// 第二个语言会把第一个语言的请求打断。
///
/// 所以这里给每个目标语言配一个独立 coordinator，各自挂一个 `.translationTask`。
/// 宿主是一个 1×1、完全透明的面板：Input Assist 开着时它就常驻，
/// 这样即使用户关掉了主窗口，Apple 翻译 session 依然活着。
@MainActor
final class InputAssistAppleTranslationPool: ObservableObject {
    struct Slot: Identifiable {
        let id: Int
        let coordinator: AppleTranslationCoordinator
    }

    @Published private(set) var slots: [Slot] = []

    private var hostWindow: NSWindow?

    func prepare(slotCount: Int) {
        let wanted = max(0, min(slotCount, InputAssistLanguagePolicy.maximumTargetCount))
        if slots.count < wanted {
            let additional = (slots.count..<wanted).map {
                Slot(id: $0, coordinator: AppleTranslationCoordinator())
            }
            slots.append(contentsOf: additional)
        }
        guard wanted > 0 else {
            shutdown()
            return
        }
        installHostWindowIfNeeded()
    }

    func coordinator(at index: Int) -> AppleTranslationCoordinator? {
        guard slots.indices.contains(index) else { return nil }
        return slots[index].coordinator
    }

    func cancelAll() {
        for slot in slots {
            slot.coordinator.cancel()
        }
    }

    func shutdown() {
        cancelAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        slots.removeAll()
    }

    private func installHostWindowIfNeeded() {
        if let hostWindow {
            hostWindow.orderFrontRegardless()
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // alphaValue 0 而不是 orderOut：窗口必须留在屏幕上，
        // SwiftUI 才会持续驱动 `.translationTask`，但用户完全看不见它。
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: InputAssistAppleSessionHost(pool: self))
        window.orderFrontRegardless()
        hostWindow = window
    }
}

/// 只负责把每个 coordinator 的 `.translationTask` 挂上，本身不显示任何内容。
private struct InputAssistAppleSessionHost: View {
    @ObservedObject var pool: InputAssistAppleTranslationPool

    var body: some View {
        ZStack {
            ForEach(pool.slots) { slot in
                Color.clear
                    .frame(width: 1, height: 1)
                    .appleTranslationSession(using: slot.coordinator)
            }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
}
