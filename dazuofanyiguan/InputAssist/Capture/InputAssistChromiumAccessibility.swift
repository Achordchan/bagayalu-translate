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

    /// 一次尝试的结论。
    enum EnableOutcome: Equatable {
        /// 打开成功。记下来，不再重复。
        case enabled
        /// 这个应用根本不支持这个属性（非 Chromium）。记下来，不再重复。
        case permanentlyUnsupported
        /// 目标应用正忙、刚启动还没起来、或辅助功能 API 临时不可用。
        /// **绝不能记**——记了就等于把这个应用永久废掉。
        case transientFailure
    }

    /// 把 `AXError` 翻成"要不要记住这个结论"。
    ///
    /// 纯函数，好让"哪些错误算永久"这件事能被单测钉住——
    /// 判错的代价是一个应用从此再也不重试，直到它或翻译官重启。
    static func classify(_ error: AXError) -> EnableOutcome {
        switch error {
        case .success:
            return .enabled
        case .attributeUnsupported, .notImplemented:
            // 这个属性它永远不会支持，再试多少次都一样。
            return .permanentlyUnsupported
        default:
            // .cannotComplete（应用没响应）、.apiDisabled（权限刚被关掉）、
            // .invalidUIElement（进程刚退出）等等，全都可能下一次就好了。
            return .transientFailure
        }
    }

    /// 已经成功打开过的进程。只在取词失败时才去开，不对每个切换到的应用都动手：
    /// 这是在让**别人的进程**多干活，不该默认施加。
    private static var enabledProcessIdentifiers = Set<pid_t>()
    /// 明确不支持这个属性的进程（非 Chromium）。
    private static var unsupportedProcessIdentifiers = Set<pid_t>()

    /// 返回 true 表示这次确实新打开了一个应用的 AX 树，调用方应该等一下再重试取词。
    @discardableResult
    static func enableIfNeeded(pid: pid_t) -> Bool {
        guard pid > 0, !hasSettledResult(pid: pid) else { return false }

        let application = AXUIElementCreateApplication(pid)
        let error = AXUIElementSetAttributeValue(
            application,
            attribute as CFString,
            kCFBooleanTrue
        )

        switch classify(error) {
        case .enabled:
            enabledProcessIdentifiers.insert(pid)
            return true
        case .permanentlyUnsupported:
            unsupportedProcessIdentifiers.insert(pid)
            return false
        case .transientFailure:
            // 什么都不记，下次还要再试。
            return false
        }
    }

    /// 这个进程是否已经有**结论**了（打开成功，或明确不支持）。
    ///
    /// 瞬时失败不算——那种情况下一次必须重试。
    static func hasSettledResult(pid: pid_t) -> Bool {
        enabledProcessIdentifiers.contains(pid)
            || unsupportedProcessIdentifiers.contains(pid)
    }

    static func reset() {
        enabledProcessIdentifiers.removeAll()
        unsupportedProcessIdentifiers.removeAll()
    }
}
