import Foundation

/// 承载流式投影器状态的盒子。
///
/// 盒子可能在非主线程上创建（`OpenAICompatibleEngine.translate` 不是 @MainActor），
/// 但 `session` 只会在 @MainActor 的流式回调里读写，且回调是串行执行的，
/// 因此不需要额外同步。
final class StreamingProjectorBox: @unchecked Sendable {
    var session = OpenAIStreamingTranslationProjector.Session()

    init() {}
}

enum OpenAIStreamingTranslationProjector {
    /// 一次性解析整段累积文本。保持原有语义，供非流式调用与测试使用。
    static func visibleText(from accumulatedText: String, isAutoDetect: Bool) -> String? {
        var session = Session()
        return session.project(from: accumulatedText, isAutoDetect: isAutoDetect)
    }

    /// 流式投影器：只解析每个 delta 新增的字符。
    ///
    /// 服务端每收到一个 delta 就会带着「完整累积文本」回调一次。旧实现每次都从头重扫整段文本，
    /// 并为每个 delta 新建一个 JSONDecoder 做全量解码（还带一个回溯重试循环），
    /// 主线程开销随译文长度呈二次增长。这里记住上次扫描停下的位置，只处理新增字符，
    /// 并自行增量解码 JSON 转义，摊还后每个 delta 只付出 O(新增长度) 的代价。
    struct Session {
        /// 候选键，按优先级排列。
        ///
        /// 旧实现是无状态的：每个 delta 都重新按这个顺序把两个键各试一遍，谁先给出字符串值就用谁。
        /// 这里给每个键配一个互相独立的增量解析器，同样每次都按优先级取第一个有结果的，
        /// 只是把「重新试一遍」变成了「各自往前推进新增的那几个字符」。
        private static let candidateKeys = ["\"translatedText\"", "\"translated_text\""]

        private var parsers = candidateKeys.map(KeyValueParser.init(key:))
        /// 上一次收到的累积文本长度，仅作兜底：正常情况下上游会用显式的替换标志通知重置。
        private var seenUTF8Count = 0

        init() {}

        mutating func project(from accumulatedText: String, isAutoDetect: Bool) -> String? {
            guard isAutoDetect else { return accumulatedText }

            // 换流和权威全文替换由上游通过显式标志通知（见 OpenAICompatibleEngine）。
            // 这里只留一个兜底：文本变短一定不是追加。
            let utf8Count = accumulatedText.utf8.count
            if utf8Count < seenUTF8Count {
                self = Session()
            }
            seenUTF8Count = utf8Count

            for index in parsers.indices {
                if let value = parsers[index].advance(over: accumulatedText, utf8Count: utf8Count) {
                    return value
                }
            }
            return nil
        }
    }

    /// 单个键的增量解析器，对应旧实现里的 `jsonStringPrefix(forKey:in:)`。
    ///
    /// 语义完全一致：找到键、校验 `:` 和起始引号、增量解码字符串值。
    /// 键还没出现、结构还没读全、或者确定这个键给不出字符串值时，都返回 nil。
    private struct KeyValueParser {
        private enum Phase {
            /// 还没定位到这个键。
            case searchingKey
            /// 已找到键，等待 `:`。
            case awaitingColon
            /// 已读到 `:`，等待值的起始引号。
            case awaitingQuote
            /// 正在读字符串值。
            case readingValue
            /// 读到了闭合引号。
            case finished
            /// 这个键确定给不出字符串值（值不是字符串，或含非法转义）。
            ///
            /// 旧实现只看键的第一次出现，而第一次出现的位置不会随文本增长而改变，
            /// 所以这个结论是永久的。
            case failed
        }

        /// 键有可能被切在两个 delta 中间，因此每次搜索都往回重叠这么多字节。
        /// `"translated_text"` 带引号共 17 字节，取 20 足够。
        private static let keySearchOverlap = 20

        private let key: String
        private var phase: Phase = .searchingKey
        /// 搜索键时的起始偏移，避免键始终不出现时每次都重扫整段文本。
        private var keySearchOffset = 0
        /// 已消费到的位置，用 UTF-8 偏移记录（String.Index 不能跨 String 实例复用）。
        private var scanOffset = 0
        private var decoded = ""
        /// JSON 用两个 \u 转义表示的代理对，高位先到时先暂存。
        private var pendingHighSurrogate: UInt32?

        init(key: String) {
            self.key = key
        }

        mutating func advance(over text: String, utf8Count: Int) -> String? {
            if phase == .searchingKey {
                locateKey(in: text, utf8Count: utf8Count)
            }

            switch phase {
            case .searchingKey, .failed:
                return nil
            case .finished:
                return decoded
            case .awaitingColon, .awaitingQuote, .readingValue:
                consume(text, utf8Count: utf8Count)
                switch phase {
                case .failed:
                    return nil
                case .awaitingColon, .awaitingQuote:
                    // 结构还没读全（例如 `:` 还在下一个 delta 里），这个键暂时给不出值。
                    return nil
                default:
                    return decoded
                }
            }
        }

        private mutating func locateKey(in text: String, utf8Count: Int) {
            let searchStart = index(in: text, atUTF8Offset: keySearchOffset, utf8Count: utf8Count)

            if let found = text.range(of: key, range: searchStart..<text.endIndex) {
                scanOffset = text.utf8.distance(from: text.utf8.startIndex, to: found.upperBound)
                phase = .awaitingColon
                return
            }

            // 没找到就把搜索起点推到接近末尾，只保留一个键长度的重叠。
            // 从末尾按字符往回退，保证偏移落在字符边界上：UTF-8 偏移若切在多字节字符中间，
            // 用它构造出来的 String.Index 不能安全地传给字符串 API。
            var boundary = text.endIndex
            var walkedBytes = 0
            while walkedBytes < Self.keySearchOverlap, boundary > text.startIndex {
                let previous = text.index(before: boundary)
                walkedBytes += text[previous].utf8.count
                boundary = previous
            }
            keySearchOffset = max(keySearchOffset, utf8Count - walkedBytes)
        }

        private mutating func consume(_ text: String, utf8Count: Int) {
            var cursor = index(in: text, atUTF8Offset: scanOffset, utf8Count: utf8Count)

            /// 记录消费进度。只在能安全恢复的位置调用，未读完的转义序列不会被记进去。
            func commit(_ index: String.Index) {
                cursor = index
                scanOffset = text.utf8.distance(from: text.utf8.startIndex, to: index)
            }

            if phase == .awaitingColon {
                guard let next = skipWhitespace(in: text, from: cursor) else { return }
                guard text[next] == ":" else {
                    phase = .failed
                    return
                }
                commit(text.index(after: next))
                phase = .awaitingQuote
            }

            if phase == .awaitingQuote {
                // 值不是字符串（例如 translatedText 为 null）时，这个键就废了，
                // 由 Session 去取下一个候选键的结果。
                guard let next = skipWhitespace(in: text, from: cursor) else { return }
                guard text[next] == "\"" else {
                    phase = .failed
                    return
                }
                commit(text.index(after: next))
                phase = .readingValue
            }

            guard phase == .readingValue else { return }

            while cursor < text.endIndex {
                let character = text[cursor]

                if character == "\"" {
                    commit(text.index(after: cursor))
                    phase = .finished
                    return
                }

                if character != "\\" {
                    decoded.append(character)
                    commit(text.index(after: cursor))
                    continue
                }

                // 转义序列：读不全就原地停下，等下一个 delta 补齐。
                let escapeStart = cursor
                let escapeIndex = text.index(after: escapeStart)
                guard escapeIndex < text.endIndex else { return }

                let escaped = text[escapeIndex]
                if escaped != "u" {
                    guard let unescaped = Self.simpleEscape(escaped) else {
                        // 非法转义序列。旧实现此时 JSONDecoder 会解码失败并对这个键返回 nil，
                        // 外层随即去试下一个键，这里保持一致。
                        phase = .failed
                        return
                    }
                    decoded.append(unescaped)
                    commit(text.index(after: escapeIndex))
                    continue
                }

                guard let (scalarValue, afterHex) = readHexQuad(
                    in: text,
                    from: text.index(after: escapeIndex)
                ) else {
                    return
                }
                appendUnicodeEscape(scalarValue)
                commit(afterHex)
            }
        }

        /// 把 \uXXXX 解出来的码位写进结果，同时处理代理对。
        private mutating func appendUnicodeEscape(_ value: UInt32) {
            if let high = pendingHighSurrogate {
                pendingHighSurrogate = nil
                if (0xDC00...0xDFFF).contains(value) {
                    let combined = 0x10000
                        + ((high - 0xD800) << 10)
                        + (value - 0xDC00)
                    if let scalar = Unicode.Scalar(combined) {
                        decoded.unicodeScalars.append(scalar)
                    }
                    return
                }
                // 高位代理后面没跟低位，丢弃这个孤立代理，继续处理当前码位。
            }

            if (0xD800...0xDBFF).contains(value) {
                pendingHighSurrogate = value
                return
            }
            if (0xDC00...0xDFFF).contains(value) {
                // 孤立的低位代理，直接忽略。
                return
            }
            if let scalar = Unicode.Scalar(value) {
                decoded.unicodeScalars.append(scalar)
            }
        }

        private func readHexQuad(
            in text: String,
            from start: String.Index
        ) -> (value: UInt32, next: String.Index)? {
            var index = start
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard index < text.endIndex,
                      let digit = text[index].hexDigitValue else {
                    return nil
                }
                value = value << 4 | UInt32(digit)
                index = text.index(after: index)
            }
            return (value, index)
        }

        private func skipWhitespace(in text: String, from start: String.Index) -> String.Index? {
            var index = start
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            return index < text.endIndex ? index : nil
        }

        private func index(in text: String, atUTF8Offset offset: Int, utf8Count: Int) -> String.Index {
            guard offset > 0 else { return text.startIndex }
            guard offset < utf8Count else { return text.endIndex }
            return text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        }

        /// JSON 规定的单字符转义。返回 nil 表示这是一个非法转义序列。
        private static func simpleEscape(_ character: Character) -> Character? {
            switch character {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "\"", "\\", "/": return character
            default: return nil
            }
        }
    }
}
