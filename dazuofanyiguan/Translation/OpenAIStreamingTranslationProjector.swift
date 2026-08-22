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
        private enum Phase {
            /// 还没定位到 translatedText 这个键。
            case searchingKey
            /// 已找到键，等待 `:`。
            case awaitingColon
            /// 已读到 `:`，等待值的起始引号。
            case awaitingQuote
            /// 正在读字符串值。
            case readingValue
            /// 读到了闭合引号。
            case finished
            /// 结构不符合预期，后续一律不再投影（与旧实现返回 nil 的行为一致）。
            case failed
        }

        /// `"translatedText"` 带引号共 16 字节，`"translated_text"` 共 17 字节。
        /// 键有可能被切在两个 delta 中间，因此每次搜索都往回重叠这么多字节。
        private static let keySearchOverlap = 20
        private static let primaryKey = "\"translatedText\""
        private static let fallbackKey = "\"translated_text\""

        private var phase: Phase = .searchingKey
        /// 已消费到的位置，用 UTF-8 偏移记录（String.Index 不能跨 String 实例复用）。
        private var scanOffset = 0
        /// 搜索键时的起始偏移，避免键始终不出现时每次都重扫整段文本。
        private var keySearchOffset = 0
        private var decoded = ""
        /// JSON 用两个 \u 转义表示的代理对，高位先到时先暂存。
        private var pendingHighSurrogate: UInt32?
        /// 上一次收到的累积文本长度与结尾指纹，用来确认这次确实是它的延续。
        private var seenUTF8Count = 0
        private var seenFingerprint: [UInt8] = []

        init() {}

        mutating func project(from accumulatedText: String, isAutoDetect: Bool) -> String? {
            guard isAutoDetect else { return accumulatedText }

            // 累积文本正常只会追加。一旦不是上次内容的延续，说明上游重新发起了一次流式请求
            // （例如 Responses 精简参数回退、或译文疑似原文回显后的重试），需要重头解析。
            if !AppendOnlyStreamCheck.isContinuation(
                of: accumulatedText,
                previousUTF8Count: seenUTF8Count,
                previousFingerprint: seenFingerprint
            ) {
                self = Session()
            }
            let utf8Count = accumulatedText.utf8.count
            seenUTF8Count = utf8Count
            seenFingerprint = AppendOnlyStreamCheck.fingerprint(
                of: accumulatedText,
                endingAt: utf8Count
            )

            if phase == .searchingKey {
                locateKey(in: accumulatedText, utf8Count: utf8Count)
            }

            switch phase {
            case .searchingKey, .failed:
                return nil
            case .finished:
                return decoded
            case .awaitingColon, .awaitingQuote, .readingValue:
                consume(accumulatedText, utf8Count: utf8Count)
                switch phase {
                case .failed:
                    return nil
                case .awaitingColon, .awaitingQuote:
                    // 结构还没读全（例如 `:` 还在下一个 delta 里），先不投影。
                    return nil
                default:
                    return decoded
                }
            }
        }

        private mutating func locateKey(in text: String, utf8Count: Int) {
            let searchStart = index(in: text, atUTF8Offset: keySearchOffset, utf8Count: utf8Count)

            for key in [Self.primaryKey, Self.fallbackKey] {
                guard let found = text.range(of: key, range: searchStart..<text.endIndex) else {
                    continue
                }
                scanOffset = text.utf8.distance(from: text.utf8.startIndex, to: found.upperBound)
                phase = .awaitingColon
                return
            }

            // 没找到就把搜索起点推到接近末尾，只保留一个键长度的重叠。
            // 从末尾按字符往回退，保证偏移落在字符边界上（UTF-8 偏移若切在多字节字符中间，
            // 用它构造出来的 String.Index 不能安全地传给字符串 API）。
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
                        // 非法转义序列。旧实现会把整段交给 JSONDecoder 并失败返回 nil，
                        // 这里同样不再投影，保持行为一致。
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
