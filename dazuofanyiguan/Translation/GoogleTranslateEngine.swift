import Foundation

struct GoogleTranslateEngine: TranslationEngine {
    let title: String = "Google 翻译"

    enum EngineError: LocalizedError {
        case textTooLong(limit: Int)
        case invalidResponse
        case methodNotAllowed

        var errorDescription: String? {
            switch self {
            case .textTooLong(let limit):
                return "Google 翻译单次最多 \(limit) 个字符，请缩短后重试"
            case .invalidResponse:
                return "Google 翻译返回无法解析"
            case .methodNotAllowed:
                return "Google 翻译接口拒绝 POST，请稍后重试或改用其他翻译服务"
            }
        }
    }

    /// 非官方 gtx 接口对长度敏感；只走 POST 表单，禁止把原文放进 URL query。
    private static let maxChunkCharacters = 1800
    private static let maxTotalCharacters = 8000
    static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!

    private let http = HTTPClient()

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> TranslationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TranslationResult(translatedText: "", detectedSourceLanguageCode: nil)
        }
        if trimmed.count > Self.maxTotalCharacters {
            throw EngineError.textTooLong(limit: Self.maxTotalCharacters)
        }

        let chunks = chunkText(trimmed, maxCharacters: Self.maxChunkCharacters)
        var translatedParts: [String] = []
        var detected: String?

        for (index, chunk) in chunks.enumerated() {
            let part = try await translateChunk(
                chunk,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
            translatedParts.append(part.translatedText)
            if detected == nil {
                detected = part.detectedSourceLanguageCode
            }
            // 简单节流，降低连发失败概率。
            if index + 1 < chunks.count {
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        return TranslationResult(
            translatedText: translatedParts.joined(),
            detectedSourceLanguageCode: detected
        )
    }

    private func translateChunk(
        _ text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> TranslationResult {
        let request = Self.makePostRequest(
            text: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
        do {
            let data = try await http.data(for: request)
            return try parseResponse(data)
        } catch let error as HTTPClient.HTTPError {
            if case .badStatus(let code, _) = error, code == 405 || code == 501 {
                throw EngineError.methodNotAllowed
            }
            throw error
        }
    }

    /// 构造仅使用 POST body 的请求；URL 不带 query，避免原文进入代理/网关日志。
    static func makePostRequest(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded;charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(
            formBody(
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                text: text
            ).utf8
        )
        return request
    }

    static func formBody(
        sourceLanguageCode: String,
        targetLanguageCode: String,
        text: String
    ) -> String {
        let items: [(String, String)] = [
            ("client", "gtx"),
            ("sl", sourceLanguageCode),
            ("tl", targetLanguageCode),
            ("dt", "t"),
            ("q", text)
        ]
        return items
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return set
    }()

    private func parseResponse(_ data: Data) throws -> TranslationResult {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [Any] else {
            throw EngineError.invalidResponse
        }

        var translated = ""
        if let sentences = root.first as? [Any] {
            for item in sentences {
                if let seg = item as? [Any], let part = seg.first as? String {
                    translated += part
                }
            }
        }
        let detected = root.count > 2 ? root[2] as? String : nil
        return TranslationResult(translatedText: translated, detectedSourceLanguageCode: detected)
    }

    private func chunkText(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            var split = end
            if end < text.endIndex {
                // 优先在段落或空白处切断，降低句子被硬切概率。
                let window = text[index..<end]
                if let nl = window.lastIndex(of: "\n") {
                    split = text.index(after: nl)
                } else if let space = window.lastIndex(where: { $0.isWhitespace }) {
                    split = text.index(after: space)
                }
            }
            if split <= index {
                split = end
            }
            chunks.append(String(text[index..<split]))
            index = split
        }
        return chunks
    }
}
