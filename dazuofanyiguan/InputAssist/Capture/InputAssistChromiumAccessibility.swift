import AppKit
import ApplicationServices
import Foundation

/// 让 Chromium / Electron 应用把辅助功能树建起来。
///
/// Chromium 默认**不维护** AX 树——维护一棵完整的树对渲染进程有实打实的开销，
/// 所以它做成按需构建：只有当某个客户端明确表示需要时才建。在那之前，
/// 焦点元素上既读不到 `kAXSelectedText` 也读不到 `kAXValue`，
/// `InputAssistAXTextCapture.capability(of:)` 判成 `.unavailable`，取词返回 nil。
///
/// 表现就是「在 Claude、Slack、Discord、VS Code、Notion、Chrome 里按快捷键没反应」——
/// 快捷键其实触发了，是取词这一步拿不到东西。
///
/// 打开的方式是给应用的 AX 对象设 `AXManualAccessibility`。
///
/// **刻意不用 `AXEnhancedUserInterface`**：那是 VoiceOver 的总开关，对非 Chromium 应用
/// 同样生效，已知会让部分应用窗口尺寸错乱、Java 应用行为异常。
/// `AXManualAccessibility` 是 Chromium 自己提供的入口，作用范围正好只有它。
@MainActor
enum InputAssistChromiumAccessibility {
    static let attribute = "AXManualAccessibility"

    /// Chromium 是**异步**建树的，设完标志要等一下才读得到内容。
    ///
    /// 200ms 是个起步值，没有实测依据——真实需要多久取决于页面复杂度。
    /// 重试仍然失败时会明确提示用户再选一次，不会静默失败。
    static let settleNanoseconds: UInt64 = 200_000_000

    /// 已经打过招呼的进程。只在取词失败时才去开，不对每个切换到的应用都动手：
    /// 这是在让**别人的进程**多干活，不该默认施加。
    private static var enabledProcessIdentifiers = Set<pid_t>()

    /// 返回 true 表示这次确实新打开了一个应用的 AX 树，调用方应该等一下再重试取词。
    ///
    /// 非 Chromium 应用会返回 `attributeUnsupported`，此时返回 false——
    /// 重试也没有意义，问题不在这里。无论成功与否都记下来，不重复尝试。
    @discardableResult
    static func enableIfNeeded(pid: pid_t) -> Bool {
        guard pid > 0, !enabledProcessIdentifiers.contains(pid) else { return false }
        enabledProcessIdentifiers.insert(pid)
        let application = AXUIElementCreateApplication(pid)
        return AXUIElementSetAttributeValue(
            application,
            attribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    /// 是否已经对这个进程打开过。
    static func isEnabled(pid: pid_t) -> Bool {
        enabledProcessIdentifiers.contains(pid)
    }

    static func reset() {
        enabledProcessIdentifiers.removeAll()
    }
}
