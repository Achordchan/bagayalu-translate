import Carbon
import Foundation

/// 当前键盘输入源（TIS）。
///
/// 只用来回答一个问题：**现在是不是有中日韩输入法开着？**
/// 如果是，那么「新出现的一串 ASCII 字母」多半是还没上屏的拼音，而不是用户真的想输入英文。
enum InputAssistInputSourceMonitor {
    static var isCJKInputSourceActive: Bool {
        containsCJKLanguage(currentInputSourceLanguages())
    }

    static func currentInputSourceLanguages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return []
        }
        guard let pointer = TISGetInputSourceProperty(
            source,
            kTISPropertyInputSourceLanguages
        ) else {
            return []
        }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return (languages as? [String]) ?? []
    }

    /// 纯判定，方便单测。
    static func containsCJKLanguage(_ languages: [String]) -> Bool {
        languages.contains { isCJKLanguage($0) }
    }

    static func isCJKLanguage(_ code: String) -> Bool {
        let base = code
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .lowercased()
        switch base {
        case "zh", "ja", "ko":
            return true
        default:
            return false
        }
    }
}
