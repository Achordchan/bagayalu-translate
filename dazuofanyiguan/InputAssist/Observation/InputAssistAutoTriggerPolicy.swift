import Foundation

enum InputAssistAutoTriggerSkipReason: String, Equatable {
    case empty
    case noChineseText
    case looksStructured
    case tooLong
}

enum InputAssistAutoTriggerDecision: Equatable {
    /// 原生输入法还在组字，什么都别做（PRD §8.2）。
    case composing
    /// 需要等用户停顿（PRD §8.1 停顿触发）。
    case waitForPause
    /// 强标点，语义边界已成立，可以绕过普通 debounce（PRD §8.1）。
    case triggerImmediately
    case skip(InputAssistAutoTriggerSkipReason)
}

/// 自动触发的判定规则（PRD §8）。
///
/// 纯函数：输入是「这一轮新出现的文字 + 当前输入法是不是 CJK」，输出是要不要弹。
/// 之所以能做到这么简单，是因为整条链路刻意不去猜「输入法有没有在组字」，
/// 而是只看**新出现的文字长什么样**——详见 `InputAssistAutoTriggerController` 的注释。
enum InputAssistAutoTriggerPolicy {
    /// 一次自动触发能覆盖的最大字数。超过基本是粘贴而不是打字，
    /// 也超出了 PRD §9.2 给上下文定的量级。
    static let maximumNewTextCharacters = 300

    static func classify(
        newText: String,
        isCJKInputSourceActive: Bool
    ) -> InputAssistAutoTriggerDecision {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skip(.empty) }
        guard trimmed.count <= maximumNewTextCharacters else { return .skip(.tooLong) }

        guard containsHan(trimmed) else {
            // 中文输入法开着、新出现的却全是 ASCII 字母：这是还没上屏的拼音。
            // 此时绝不能弹——弹出来翻译的是 "women keyi"，不是「我们可以」。
            if isCJKInputSourceActive, isLikelyRomanizationBuffer(trimmed) {
                return .composing
            }
            // 自动触发第一版只针对新增中文（PRD §8.3）。
            return .skip(.noChineseText)
        }

        guard !InputAssistSentenceBoundary.looksLikeURL(trimmed),
              !InputAssistSentenceBoundary.looksLikeEmail(trimmed) else {
            return .skip(.looksStructured)
        }

        if endsWithStrongTerminator(trimmed) {
            return .triggerImmediately
        }
        return .waitForPause
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // 扩展 A
                 0x4E00...0x9FFF,   // 基本区
                 0xF900...0xFAFF:   // 兼容汉字
                return true
            default:
                return false
            }
        }
    }

    /// 看起来像还没上屏的拼音 / 罗马字缓冲区：只有 ASCII 字母、数字和分隔符。
    ///
    /// 数字要算进去，因为拼音候选是用数字键选的；
    /// 隔音符号 `'` 也允许（xi'an）。
    static func isLikelyRomanizationBuffer(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var sawLetter = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                sawLetter = true
            case 0x30...0x39, 0x20, 0x27:
                continue
            default:
                return false
            }
        }
        return sawLetter
    }

    /// 强句界（PRD §8.1）。弱标点（，、）不算，不得只因为逗号就切断。
    static func endsWithStrongTerminator(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        guard !InputAssistSentenceBoundary.weakSeparators.contains(last) else { return false }
        return InputAssistSentenceBoundary.strongTerminators.contains(last)
    }
}

/// 停顿触发的等待时长（PRD §8.1）。
enum InputAssistTriggerSpeed: String, CaseIterable, Identifiable {
    case fast
    case standard
    case steady
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "快速"
        case .standard: return "默认"
        case .steady: return "稳定"
        case .custom: return "自定义"
        }
    }

    var presetMilliseconds: Int? {
        switch self {
        case .fast: return 200
        case .standard: return 300
        case .steady: return 500
        case .custom: return nil
        }
    }

    static let customRange = 100...1000

    static func milliseconds(speed: InputAssistTriggerSpeed, customMilliseconds: Int) -> Int {
        if let preset = speed.presetMilliseconds { return preset }
        return min(max(customMilliseconds, customRange.lowerBound), customRange.upperBound)
    }
}
