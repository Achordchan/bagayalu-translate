import Foundation

/// AX 的 CFRange 以 UTF-16 code unit 计数，整条链路统一用它，避免中途换算出错。
struct InputAssistTextRange: Equatable {
    let location: Int
    let length: Int

    var upperBound: Int { location + length }
    var isEmpty: Bool { length <= 0 }
}

/// 句界识别与上下文截取（PRD §9）。
enum InputAssistSentenceBoundary {
    /// 强句界：到这里就认为语义边界成立（PRD §9.3 / §8.1）。
    static let strongTerminators: Set<Character> = [
        "。", "！", "？", "；", "!", "?", ";", ".", "\n", "\r"
    ]

    /// 弱分隔：不得只因为逗号就切断翻译范围（PRD §8.1）。
    static let weakSeparators: Set<Character> = ["，", "、", ","]

    static let defaultContextCharacterLimit = 300

    /// caret 之前最近的一句（PRD §9.3 / §26.2）。
    ///
    /// 返回 nil 表示这段没有可翻译内容——调用方应当放弃，而不是退而求其次
    /// 去猜一个范围出来（PRD §28「确认不了就别动」）。
    static func currentSentenceRange(
        in text: String,
        caretUTF16Offset: Int
    ) -> InputAssistTextRange? {
        guard !text.isEmpty else { return nil }
        let caret = clampedIndex(in: text, utf16Offset: caretUTF16Offset)
        guard caret > text.startIndex else { return nil }

        // caret 紧邻的那个终止符属于当前句，先跳过它再往前找上一个句界。
        var scan = text.index(before: caret)
        if isStrongTerminator(text[scan]) {
            guard scan > text.startIndex else {
                return range(from: text.startIndex, to: caret, in: text)
            }
            scan = text.index(before: scan)
        }

        var start = text.startIndex
        while scan >= text.startIndex {
            if isStrongTerminator(text[scan], in: text, at: scan) {
                start = text.index(after: scan)
                break
            }
            if scan == text.startIndex { break }
            scan = text.index(before: scan)
        }

        // 句首的空白不进翻译范围，否则替换会把用户敲的空格一起吃掉。
        while start < caret, text[start].isWhitespace {
            start = text.index(after: start)
        }
        guard start < caret else { return nil }
        guard text[start..<caret].contains(where: { !$0.isWhitespace }) else { return nil }

        return range(from: start, to: caret, in: text)
    }

    /// 上下文：目标句之前再往回补 1–2 句，总长不超过上限（PRD §9.2）。
    ///
    /// 上下文只用于让引擎理解，替换范围仍然只有 sourceRange 本身（PRD §9.1）。
    static func context(
        in text: String,
        sourceRange: InputAssistTextRange,
        characterLimit: Int = defaultContextCharacterLimit,
        maximumPrecedingSentences: Int = 2
    ) -> String {
        guard !text.isEmpty, !sourceRange.isEmpty else { return "" }
        let sourceStart = clampedIndex(in: text, utf16Offset: sourceRange.location)
        let sourceEnd = clampedIndex(in: text, utf16Offset: sourceRange.upperBound)
        guard sourceStart < sourceEnd else { return "" }

        var start = sourceStart
        var sentencesTaken = 0
        while sentencesTaken < maximumPrecedingSentences, start > text.startIndex {
            guard let previous = currentSentenceRange(
                in: text,
                caretUTF16Offset: start.utf16Offset(in: text)
            ) else {
                break
            }
            let previousStart = clampedIndex(in: text, utf16Offset: previous.location)
            guard previousStart < start else { break }
            let candidateLength = text.distance(from: previousStart, to: sourceEnd)
            guard candidateLength <= characterLimit else { break }
            start = previousStart
            sentencesTaken += 1
        }

        let context = String(text[start..<sourceEnd])
        guard context.count > characterLimit else { return context }
        return String(context.suffix(characterLimit))
    }

    /// 这段文字看起来值不值得翻译。
    ///
    /// 不设最小字数（PRD §9.4：「好的」「收到」必须支持），
    /// 只挡掉明显不该动的结构化内容（PRD §8.3）。
    static func looksTranslatable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains(where: { $0.isLetter }) else { return false }
        guard !looksLikeURL(trimmed), !looksLikeEmail(trimmed) else { return false }
        return true
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.") {
            return true
        }
        // 单个 token 且带域名点号，例如 example.com/path
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        return lowered.contains("://")
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".")
    }

    // MARK: - Helpers

    private static func isStrongTerminator(_ character: Character) -> Bool {
        strongTerminators.contains(character)
    }

    /// 半角句点要多看一眼：夹在数字中间的是小数点（12.5）或版本号，不是句界。
    private static func isStrongTerminator(
        _ character: Character,
        in text: String,
        at index: String.Index
    ) -> Bool {
        guard strongTerminators.contains(character) else { return false }
        guard character == "." else { return true }
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else { return true }
        return !(previous.isNumber && text[nextIndex].isNumber)
    }

    private static func clampedIndex(in text: String, utf16Offset: Int) -> String.Index {
        let total = text.utf16.count
        let clamped = min(max(utf16Offset, 0), total)
        guard let index = String.Index(utf16Offset: clamped, in: text).samePosition(in: text) else {
            return text.endIndex
        }
        return index
    }

    private static func range(
        from start: String.Index,
        to end: String.Index,
        in text: String
    ) -> InputAssistTextRange {
        let location = start.utf16Offset(in: text)
        return InputAssistTextRange(
            location: location,
            length: end.utf16Offset(in: text) - location
        )
    }
}
