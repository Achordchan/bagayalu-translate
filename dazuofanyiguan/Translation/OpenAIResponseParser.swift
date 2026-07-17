import Foundation

/// OpenAI 兼容接口的响应解析与自动检测 JSON 提取。
enum OpenAIResponseParser {
    struct ChatCompletionsResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message?
        }
        let choices: [Choice]?
    }

    struct ResponsesResponse: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let text: String?
                let type: String?
            }
            let content: [Content]?
        }

        let output_text: String?
        let output: [Output]?
    }

    struct AutoDetectPayload: Equatable {
        let detectedSourceLanguageCode: String?
        let translatedText: String?
    }

    static func contentText(
        from data: Data,
        endpointMode: OpenAIEndpointMode
    ) throws -> String {
        let decoder = JSONDecoder()
        switch endpointMode {
        case .chatCompletions:
            let decoded = try decoder.decode(ChatCompletionsResponse.self, from: data)
            return decoded.choices?.first?.message?.content?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .responses:
            let decoded = try decoder.decode(ResponsesResponse.self, from: data)
            if let text = decoded.output_text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            return decoded.output?.first?.content?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    static func extractJSONObjectString(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.count >= 2 {
                let withoutFirst = lines.dropFirst().joined(separator: "\n")
                if let lastFence = withoutFirst.range(of: "```", options: .backwards) {
                    return String(withoutFirst[..<lastFence.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            if start <= end {
                return String(trimmed[start...end])
            }
        }
        return trimmed
    }

    static func decodeAutoDetectPayload(from jsonString: String) -> AutoDetectPayload? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        if let container = try? JSONDecoder().decode([String: String?].self, from: data) {
            let detected = container["detectedSourceLanguageCode"]
                ?? container["detected_source_language_code"]
                ?? container["detected_source"]
                ?? nil
            let translated = container["translatedText"]
                ?? container["translated_text"]
                ?? container["translation"]
                ?? nil
            return AutoDetectPayload(
                detectedSourceLanguageCode: detected ?? nil,
                translatedText: translated ?? nil
            )
        }

        if let keyed = try? JSONDecoder().decode([String: String].self, from: data) {
            let detected = keyed["detectedSourceLanguageCode"]
                ?? keyed["detected_source_language_code"]
                ?? keyed["detected_source"]
            let translated = keyed["translatedText"]
                ?? keyed["translated_text"]
                ?? keyed["translation"]
            return AutoDetectPayload(
                detectedSourceLanguageCode: detected,
                translatedText: translated
            )
        }

        if let root = try? JSONDecoder().decode([String: AnyDecodable].self, from: data) {
            let detected = root["detectedSourceLanguageCode"]?.stringValue
                ?? root["detected_source_language_code"]?.stringValue
                ?? root["detected_source"]?.stringValue
            let translated = root["translatedText"]?.stringValue
                ?? root["translated_text"]?.stringValue
                ?? root["translation"]?.stringValue
            return AutoDetectPayload(
                detectedSourceLanguageCode: detected,
                translatedText: translated
            )
        }

        return nil
    }

    static func parseAutoDetectResult(from content: String) -> TranslationResult? {
        let jsonString = extractJSONObjectString(from: content)
        guard let payload = decodeAutoDetectPayload(from: jsonString),
              let translated = payload.translatedText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty else {
            return nil
        }
        let detected = payload.detectedSourceLanguageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslationResult(
            translatedText: translated,
            detectedSourceLanguageCode: detected
        )
    }

    private struct AnyDecodable: Decodable {
        let stringValue: String?

        init(from decoder: Decoder) throws {
            if let c = try? decoder.singleValueContainer() {
                if let s = try? c.decode(String.self) {
                    stringValue = s
                    return
                }
                if let i = try? c.decode(Int.self) {
                    stringValue = String(i)
                    return
                }
                if let d = try? c.decode(Double.self) {
                    stringValue = String(d)
                    return
                }
                if let b = try? c.decode(Bool.self) {
                    stringValue = b ? "true" : "false"
                    return
                }
            }
            stringValue = nil
        }
    }
}
