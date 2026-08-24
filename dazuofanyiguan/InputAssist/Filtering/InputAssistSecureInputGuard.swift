import ApplicationServices
import Carbon
import Foundation

/// 输入面的能力等级（PRD §46）。
///
/// UI 不暴露 A/B/C/D，但内部必须有这个模型，
/// 否则「能不能安全替换」会散落成一堆临时判断。
enum InputAssistSurfaceCapability: Equatable {
    /// AX 能精确读写选区：直接替换，宿主 Undo 正常。
    case axDirect
    /// 能读选中文本，但无法精确验证写入：只复制译文。
    case copyOnly
    /// 完全读不到：只能放弃。
    case unavailable
}

/// 安全红线（PRD §44）。任何一条命中都必须停手。
enum InputAssistSecureInputGuard {
    /// 系统级安全输入。密码框、部分终端会开启它，
    /// 此时合成键盘事件既不可靠也不该做。
    static var isSecureEventInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// 密码类控件的 AX role。
    ///
    /// `kAXSecureTextFieldRole` 没有导出到 Swift，只能用字面量；
    /// 值来自 `AXRoleConstants.h`，不会变。
    static let secureTextFieldRole = "AXSecureTextField"

    /// AX role 是否属于必须跳过的密码类控件（PRD §24.1 / §44）。
    static func isSecureRole(_ role: String?) -> Bool {
        role == secureTextFieldRole
    }

    /// 综合判断这个输入面能不能碰。
    static func allowsAutomation(
        role: String?,
        subrole: String?,
        isSecureEventInputEnabled: Bool
    ) -> Bool {
        guard !isSecureEventInputEnabled else { return false }
        guard !isSecureRole(role) else { return false }
        if isSecureRole(subrole) { return false }
        return true
    }
}
