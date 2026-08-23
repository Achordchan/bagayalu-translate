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

    /// 自动触发的替换范围（PRD §9.1 + §9.3）。
    ///
    /// 取「这轮输入的起点」和「当前句的起点」里**靠后**的那一个作为开头：
    /// - 用输入起点，保证不会去改用户之前就写好的内容（§9.1「不得修改前文」）；
    /// - 用句起点，保证不会一次跨掉好几个完整句子（§9.3）。
    static func autoTriggerSourceRange(
        in text: String,
        burstStartUTF16Offset: Int,
        caretUTF16Offset: Int
    ) -> InputAssistTextRange? {
        guard caretUTF16Offset > burstStartUTF16Offset else { return nil }

        let sentenceStart = currentSentenceRange(
            in: text,
            caretUTF16Offset: caretUTF16Offset
        )?.location ?? burstStartUTF16Offset
        var start = max(burstStartUTF16Offset, sentenceStart)

        // 起点落在空白上时往后挪，别把用户敲的空格一起替换掉。
        while start < caretUTF16Offset {
            guard let character = InputAssistAXTextCapture.substring(
                of: text,
                range: InputAssistTextRange(location: start, length: 1)
            ) else {
                break
            }
            guard character.allSatisfy({ $0.isWhitespace }) else { break }
            start += 1
        }

        guard start < caretUTF16Offset else { return nil }
        return InputAssistTextRange(location: start, length: caretUTF16Offset - start)
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
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        if lowered.contains("://") { return true }
        return looksLikeBareDomain(text)
    }

    /// 不带协议头的域名，例如 `example.com/产品`。
    ///
    /// 这种写法很常见，而且**因为路径里可能带中文，会被自动触发当成"新增了中文"**——
    /// 只判断 `http://` 前缀和 `://` 的话，正好把它漏掉，
    /// 结果是在一条 URL 中间弹候选、甚至替换掉其中一段。
    static func looksLikeBareDomain(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }

        // 主机名到 `/`、`?`、`#` 任意一个为止——只截 `/` 的话，
        // `example.com?关键词`、`example.com#说明` 的顶级域会连着中文一起被取出来，
        // 校验失败、于是又漏回自动翻译那条路上。
        let host = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // 再去掉端口：`example.com:8080/产品` 的顶级域是 `com`，不是 `com:8080`。
        let hostWithoutPort = host.prefix { $0 != ":" }
        let labels = hostWithoutPort.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }

        // 顶级域必须是两个以上的 ASCII 字母：这样 "12.5" 这类小数不会被误判。
        guard let topLevel = labels.last,
              topLevel.count >= 2,
              topLevel.allSatisfy({ $0.isASCII && $0.isLetter })
        else {
            return false
        }
        // 其余各段是 ASCII 字母数字或连字符，于是「我们提供16吨船吊.价格面议」不会中招。
        return labels.dropLast().allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
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
