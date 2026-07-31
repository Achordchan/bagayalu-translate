import Foundation

enum OpenAIStreamingTranslationProjector {
    static func visibleText(from accumulatedText: String, isAutoDetect: Bool) -> String? {
        guard isAutoDetect else { return accumulatedText }
        for key in ["translatedText", "translated_text"] {
            if let value = jsonStringPrefix(forKey: key, in: accumulatedText) {
                return value
            }
        }
        return nil
    }

    private static func jsonStringPrefix(forKey key: String, in json: String) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound

        while index < json.endIndex, json[index].isWhitespace {
            index = json.index(after: index)
        }
        guard index < json.endIndex, json[index] == ":" else { return nil }
        index = json.index(after: index)
        while index < json.endIndex, json[index].isWhitespace {
            index = json.index(after: index)
        }
        guard index < json.endIndex, json[index] == "\"" else { return nil }
        index = json.index(after: index)

        var encoded = ""
        while index < json.endIndex {
            let character = json[index]
            if character == "\"" { break }
            if character != "\\" {
                encoded.append(character)
                index = json.index(after: index)
                continue
            }

            let escapeStart = index
            index = json.index(after: index)
            guard index < json.endIndex else { break }
            let escaped = json[index]
            if escaped == "u" {
                var end = json.index(after: index)
                for _ in 0..<4 {
                    guard end < json.endIndex, json[end].isHexDigit else {
                        return decodeJSONStringPrefix(encoded)
                    }
                    end = json.index(after: end)
                }
                encoded.append(contentsOf: json[escapeStart..<end])
                index = end
            } else {
                encoded.append(contentsOf: json[escapeStart...index])
                index = json.index(after: index)
            }
        }

        return decodeJSONStringPrefix(encoded)
    }

    private static func decodeJSONStringPrefix(_ encoded: String) -> String? {
        var candidate = encoded
        while true {
            let literal = "\"\(candidate)\""
            if let data = literal.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded
            }
            guard let slash = candidate.range(of: "\\u", options: .backwards) else { return nil }
            candidate.removeSubrange(slash.lowerBound..<candidate.endIndex)
        }
    }
}
