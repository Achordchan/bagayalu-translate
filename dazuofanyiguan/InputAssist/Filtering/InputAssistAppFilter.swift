import AppKit
import Foundation

/// 目标 App 的三个可比对标识：用户在设置里可能填其中任意一个。
struct InputAssistAppIdentity: Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
    let executableName: String?

    init(bundleIdentifier: String?, localizedName: String?, executableName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.executableName = executableName
    }

    init(application: NSRunningApplication) {
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            executableName: application.bundleURL?
                .deletingPathExtension()
                .lastPathComponent
        )
    }

    static func frontmost() -> InputAssistAppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InputAssistAppIdentity(application: app)
    }
}

enum InputAssistAppScope: String, CaseIterable, Identifiable {
    /// Mode A：全局启用 + 黑名单排除（PRD §25 默认）。
    case globalWithBlocklist
    /// Mode B：仅指定 App 启用。
    case allowlistOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globalWithBlocklist: return "全局启用"
        case .allowlistOnly: return "仅指定应用"
        }
    }
}

/// 应用黑白名单（PRD §24 / §25）。纯匹配逻辑，可直接单测。
enum InputAssistAppFilter {
    /// 默认黑名单：终端和密码类工具。
    ///
    /// 这些场景要么文本不该被翻译，要么误替换的代价特别高，
    /// 所以即使用户选了「全局启用」也先默认排除掉。
    static let defaultBlocklist: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop"
    ]

    /// 安全策略 / 黑名单优先于全局规则（PRD §25 优先级）。
    static func allows(
        _ identity: InputAssistAppIdentity?,
        scope: InputAssistAppScope,
        blocklist: [String],
        allowlist: [String]
    ) -> Bool {
        // 连当前 App 都识别不出来，就不要动它的文本。
        guard let identity else { return false }

        if matches(identity, entries: blocklist) { return false }

        switch scope {
        case .globalWithBlocklist:
            return true
        case .allowlistOnly:
            return matches(identity, entries: allowlist)
        }
    }

    /// 用户可能填 "Terminal"、"com.apple.Terminal" 或 "Terminal.app"，三种都要认。
    static func matches(_ identity: InputAssistAppIdentity, entries: [String]) -> Bool {
        guard !entries.isEmpty else { return false }
        let candidates = Set(
            [identity.bundleIdentifier, identity.localizedName, identity.executableName]
                .compactMap { $0.map(normalize) }
                .filter { !$0.isEmpty }
        )
        guard !candidates.isEmpty else { return false }
        return entries.contains { candidates.contains(normalize($0)) }
    }

    private static func normalize(_ value: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasSuffix(".app") {
            normalized.removeLast(4)
        }
        return normalized
    }
}
