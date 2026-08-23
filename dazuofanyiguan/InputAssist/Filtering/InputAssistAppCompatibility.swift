import Foundation

/// 应用兼容等级（PRD §46）。
///
/// UI 不暴露 A/B/C/D，但内部必须有这个模型，
/// 否则「这个 App 能不能自动触发」会散成一堆临时判断。
enum InputAssistCompatibilityLevel: String, Equatable, Comparable {
    /// 自动触发 + 精确光标定位 + AX 替换 + Undo。
    case full
    /// 自动触发 + 退化定位 + 粘贴替换。
    case degraded
    /// 只支持手动触发。
    case manualOnly
    /// 完全禁用。
    case disabled

    private var rank: Int {
        switch self {
        case .full: return 3
        case .degraded: return 2
        case .manualOnly: return 1
        case .disabled: return 0
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var allowsAutoTrigger: Bool { self == .full || self == .degraded }
    var allowsManualTrigger: Bool { self != .disabled }
}

enum InputAssistAppCompatibility {
    /// 已知只能手动触发的 App。
    ///
    /// 终端类即使 AX 读得到也不该自动改写命令行（PRD §53 把 Terminal 标为
    /// `blocked auto` / `manual only`）；它们同时也在默认黑名单里，
    /// 这里是第二道闸，防止用户把黑名单清空之后自动触发就直接放开了。
    static let manualOnlyBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper"
    ]

    /// 纯判定，方便单测。
    static func level(
        bundleIdentifier: String?,
        capability: InputAssistSurfaceCapability,
        hasPreciseCaretBounds: Bool
    ) -> InputAssistCompatibilityLevel {
        switch capability {
        case .unavailable:
            return .disabled
        case .pasteFallback:
            if isManualOnly(bundleIdentifier) { return .manualOnly }
            return .degraded
        case .axDirect:
            if isManualOnly(bundleIdentifier) { return .manualOnly }
            return hasPreciseCaretBounds ? .full : .degraded
        }
    }

    static func isManualOnly(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return manualOnlyBundleIdentifiers.contains(bundleIdentifier)
    }
}
