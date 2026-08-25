import Foundation

/// Commit 前的二次校验（PRD §44 / §45）。
///
/// 纯函数：把「现在读到的状态」和「生成候选时的快照」比一比，
/// 决定能不能替换。所有实际的 AX 调用都在外面完成，这样规则本身可以直接单测。
enum InputAssistReplacementSafetyGuard {
    enum Verdict: Equatable {
        /// 按记录的范围精确替换。
        case replaceRange(InputAssistTextRange)
        /// 范围不可用，但当前选区内容仍然是原文，可以替换选区。
        case replaceSelection
        case abort(reason: AbortReason)
    }

    enum AbortReason: String, Equatable {
        case secureInputActive
        case applicationChanged
        case focusLost
        case focusedElementChanged
        case selectionChanged
        /// AX 写调用返回成功，但读不回结果、无法证明到底生效没有。
        case writeVerificationUnavailable
        case sourceTextChanged
        case sourceRangeUnavailable
        /// 剪贴板正在被用户或剪贴板管理器改写。
        ///
        /// 粘贴引擎为此**刻意没有**覆盖那份新内容——调用方也不能接着去复制译文，
        /// 否则就把引擎保护的东西亲手毁掉了。
        case clipboardBusy
    }

    /// 核心不变式：
    ///
    /// > 候选生成时读到的原文，和现在这一刻目标位置上的文字，必须**逐字相同**。
    ///
    /// 只要对不上就放弃。宁可这次不翻译，也不能删错或改错用户的内容。
    static func validate(
        expectedSourceText: String,
        sourceRange: InputAssistTextRange?,
        currentElementValue: String?,
        currentSelectedText: String?,
        hasFocusedElement: Bool,
        isFocusedElementUnchanged: Bool,
        isFrontmostApplicationUnchanged: Bool,
        isSecureEventInputEnabled: Bool
    ) -> Verdict {
        guard !isSecureEventInputEnabled else {
            return .abort(reason: .secureInputActive)
        }
        guard hasFocusedElement else {
            return .abort(reason: .focusLost)
        }
        guard isFrontmostApplicationUnchanged else {
            return .abort(reason: .applicationChanged)
        }
        // 同一个 App 里换了个输入框也必须停手。
        // 只比对文本内容是不够的：另一个控件里恰好有同样的文字并不罕见
        // （搜索框和输入框都写着「好的」），那样译文就会写进完全错误的地方。
        guard isFocusedElementUnchanged else {
            return .abort(reason: .focusedElementChanged)
        }

        if let sourceRange, let currentElementValue {
            guard let currentText = InputAssistAXTextCapture.substring(
                of: currentElementValue,
                range: sourceRange
            ) else {
                // 范围越界说明用户已经删掉了一部分内容，快照作废。
                return .abort(reason: .sourceTextChanged)
            }
            guard currentText == expectedSourceText else {
                return .abort(reason: .sourceTextChanged)
            }
            return .replaceRange(sourceRange)
        }

        // 拿不到范围时只剩「当前选区还是不是那段原文」这一个凭据。
        guard let currentSelectedText else {
            return .abort(reason: .sourceRangeUnavailable)
        }
        guard currentSelectedText == expectedSourceText else {
            return .abort(reason: .sourceTextChanged)
        }
        return .replaceSelection
    }
}
