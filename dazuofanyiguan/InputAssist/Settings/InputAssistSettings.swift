import Carbon.HIToolbox
import Foundation
import SwiftUI

/// 手动触发快捷键。
struct InputAssistShortcut: Hashable {
    var keyCode: Int
    var carbonModifiers: UInt32

    /// 默认值：⌥⇧ Space。避开 Google Gemini、Alfred 等常见的 ⌥Space。
    static let `default` = InputAssistShortcut(
        keyCode: kVK_Space,
        carbonModifiers: UInt32(optionKey) | UInt32(shiftKey)
    )

    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + InputAssistShortcut.keyName(for: keyCode)
    }

    static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_J: return "J"
        default: return "Key \(keyCode)"
        }
    }

    /// 可选的快捷键组合。
    ///
    /// 快捷键可以即时更换；系统或其它 App 占用时不应让功能失去入口。
    static let selectableOptions: [InputAssistShortcut] = [
        .default,
        InputAssistShortcut(keyCode: kVK_Space, carbonModifiers: UInt32(optionKey)),
        InputAssistShortcut(keyCode: kVK_Space, carbonModifiers: UInt32(controlKey)),
        InputAssistShortcut(keyCode: kVK_ANSI_T, carbonModifiers: UInt32(optionKey)),
        InputAssistShortcut(keyCode: kVK_ANSI_G, carbonModifiers: UInt32(optionKey)),
        InputAssistShortcut(
            keyCode: kVK_ANSI_J,
            carbonModifiers: UInt32(cmdKey) | UInt32(optionKey)
        )
    ]
}

extension InputAssistShortcut: Identifiable {
    var id: String { "\(keyCode)-\(carbonModifiers)" }
}

/// Input Assist 的全部持久化配置（PRD §47）。
///
/// 存储直接走 `UserDefaults`，每个 setter 显式 `objectWillChange.send()`。
/// **没有用 `@AppStorage`**：那个属性包装器是给 View 用的，
/// 放在 `ObservableObject` 里虽然能读能写，却不会触发 `objectWillChange`，
/// 设置页上的开关点了不会立刻重绘。
@MainActor
final class InputAssistSettings: ObservableObject {
    private enum Key {
        static let isEnabled = "inputAssistEnabled"
        static let targetLanguages = "inputAssistTargetLanguages"
        static let shortcutKeyCode = "inputAssistShortcutKeyCode"
        static let shortcutModifiers = "inputAssistShortcutModifiers"
        static let appScope = "inputAssistAppScope"
        static let blocklist = "inputAssistBlocklist"
        static let allowlist = "inputAssistAllowlist"
        static let selectionAutoShowEnabled = "inputAssistSelectionAutoShowEnabled"
        static let showsCacheBadge = "inputAssistShowsCacheBadge"
        static let didOfferOnboarding = "inputAssistDidOfferOnboarding"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: false,
            Key.targetLanguages: InputAssistLanguagePolicy.defaultTargetCodes.joined(separator: ","),
            Key.shortcutKeyCode: InputAssistShortcut.default.keyCode,
            Key.shortcutModifiers: Int(InputAssistShortcut.default.carbonModifiers),
            Key.appScope: InputAssistAppScope.globalWithBlocklist.rawValue,
            Key.blocklist: InputAssistAppFilter.defaultBlocklist.joined(separator: "\n"),
            Key.allowlist: "",
            Key.selectionAutoShowEnabled: false,
            Key.showsCacheBadge: true,
            Key.didOfferOnboarding: false
        ])
    }

    /// **默认关闭。** 不得因为用户升级就自动打开系统级输入监听（PRD §6.1）。
    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { write(newValue, forKey: Key.isEnabled) }
    }

    var targetLanguageCodes: [String] {
        get {
            let stored = (defaults.string(forKey: Key.targetLanguages) ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map(String.init)
            let sanitized = InputAssistLanguagePolicy.sanitizeTargets(stored)
            return sanitized.isEmpty ? InputAssistLanguagePolicy.defaultTargetCodes : sanitized
        }
        set {
            let sanitized = InputAssistLanguagePolicy.sanitizeTargets(newValue)
            let effective = sanitized.isEmpty
                ? InputAssistLanguagePolicy.defaultTargetCodes
                : sanitized
            write(effective.joined(separator: ","), forKey: Key.targetLanguages)
        }
    }

    var shortcut: InputAssistShortcut {
        get {
            InputAssistShortcut(
                keyCode: defaults.integer(forKey: Key.shortcutKeyCode),
                carbonModifiers: UInt32(max(0, defaults.integer(forKey: Key.shortcutModifiers)))
            )
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.keyCode, forKey: Key.shortcutKeyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Key.shortcutModifiers)
        }
    }

    var appScope: InputAssistAppScope {
        get {
            InputAssistAppScope(rawValue: defaults.string(forKey: Key.appScope) ?? "")
                ?? .globalWithBlocklist
        }
        set { write(newValue.rawValue, forKey: Key.appScope) }
    }

    var blocklistText: String {
        get { defaults.string(forKey: Key.blocklist) ?? "" }
        set { write(newValue, forKey: Key.blocklist) }
    }

    var allowlistText: String {
        get { defaults.string(forKey: Key.allowlist) ?? "" }
        set { write(newValue, forKey: Key.allowlist) }
    }

    var blocklist: [String] { InputAssistSettings.parseList(blocklistText) }
    var allowlist: [String] { InputAssistSettings.parseList(allowlistText) }

    /// 选区完成后自动显示候选。默认关闭，快捷键是稳定主路径。
    var isSelectionAutoShowEnabled: Bool {
        get { defaults.bool(forKey: Key.selectionAutoShowEnabled) }
        set { write(newValue, forKey: Key.selectionAutoShowEnabled) }
    }

    /// 缓存命中的 ⚡ 标识，主要服务于早期验证（PRD §22）。
    var showsCacheBadge: Bool {
        get { defaults.bool(forKey: Key.showsCacheBadge) }
        set { write(newValue, forKey: Key.showsCacheBadge) }
    }

    /// 新功能推荐只出现一次（PRD §6.2）。
    var didOfferOnboarding: Bool {
        get { defaults.bool(forKey: Key.didOfferOnboarding) }
        set { write(newValue, forKey: Key.didOfferOnboarding) }
    }

    var exceedsRecommendedTargetCount: Bool {
        targetLanguageCodes.count > InputAssistLanguagePolicy.recommendedTargetCount
    }

    /// 纯字符串解析，不碰任何实例状态，所以标 nonisolated 让测试和后台代码都能直接用。
    nonisolated static func parseList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func write(_ value: Any, forKey key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }
}
