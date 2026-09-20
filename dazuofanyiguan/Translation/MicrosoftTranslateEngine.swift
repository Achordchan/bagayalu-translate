import Foundation

/// 微软翻译（免密）。
///
/// 走 Edge 浏览器网页翻译用的 `edge.microsoft.com/translate/translatetext`：
/// 不需要 token，请求体是字符串数组，响应和 Azure Translator v3 同构。
/// 旧的 `edge.microsoft.com/translate/auth` 换 JWT 那条路 2026-08 起已 404，不要再走。
///
/// 实测（2026-09-20）：
/// - 没有浏览器 UA 会 400 `Client Browser Version not supported`；
/// - `from=auto` 是 400，自动检测要**省略** `from`；
/// - `to=zh-CN` / `zh-TW` / `no` 服务端会自行归一成 `zh-Hans` / `zh-Hant` / `nb`，
///   但检测回来的源语言是微软自己的码（`zh-Hans`），要映射回应用内部码；
/// - 单请求 20000 字 1.3s 正常，50000 字挂 20s 后 500，60000 字直接 400。
struct MicrosoftTranslateEngine: TranslationEngine {
    let title: String = "微软翻译"

    enum EngineError: LocalizedError {
        case textTooLong(limit: Int)
        case invalidResponse
        case badRequest(detail: String)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .textTooLong(let limit):
                return "微软翻译单次最多 \(limit) 个字符，请缩短后重试"
            case .invalidResponse:
                return "微软翻译返回无法解析"
            case .badRequest(let detail):
                if detail.isEmpty {
                    return "微软翻译拒绝了本次请求，请检查所选语言是否受支持"
                }
                return "微软翻译拒绝了本次请求：\(detail)"
            case .rateLimited:
                return "微软翻译请求过于频繁，请稍后再试"
            }
        }
    }

    /// 单个数组元素的上限。服务端 2 万字仍正常，留足余量。
    static let maxChunkCharacters = 5000
    /// 单个 HTTP 请求里所有元素的字符总和上限。
    static let maxRequestCharacters = 15000
    /// 一次翻译（可能拆成多个请求）接受的原文上限。
    static let maxTotalCharacters = 30000
    static let endpoint = URL(string: "https://edge.microsoft.com/translate/translatetext")!
    /// 服务端校验 UA 是否像浏览器；这是 Edge 的桌面 UA。
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0"

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

        let chunks = Self.chunkText(trimmed, maxCharacters: Self.maxChunkCharacters)
        let batches = Self.batchChunks(chunks, maxCharacters: Self.maxRequestCharacters)

        var translatedParts: [String] = []
        var detected: String?
        for batch in batches {
            let request = Self.makeRequest(
                texts: batch,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
            let data: Data
            do {
                data = try await http.data(for: request)
            } catch let error as HTTPClient.HTTPError {
                throw Self.mapHTTPError(error)
            }
            let parsed = try Self.parseResponse(data, expectedCount: batch.count)
            translatedParts.append(contentsOf: parsed.map(\.translatedText))
            if detected == nil {
                detected = parsed.compactMap(\.detectedSourceLanguageCode).first
            }
        }

        return TranslationResult(
            translatedText: translatedParts.joined(),
            detectedSourceLanguageCode: detected
        )
    }

    // MARK: - 请求

    /// 原文只放 JSON body；URL 上只有语言参数。
    static func makeRequest(
        texts: [String],
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let from = requestLanguageCode(forSource: sourceLanguageCode) {
            items.append(URLQueryItem(name: "from", value: from))
        }
        items.append(URLQueryItem(name: "to", value: requestLanguageCode(forTarget: targetLanguageCode)))
        items.append(URLQueryItem(name: "isEnterpriseClient", value: "false"))
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: texts)
        return request
    }

    /// 自动检测时返回 nil（`from=auto` 服务端会 400，必须省略）。
    static func requestLanguageCode(forSource code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            return nil
        }
        return requestLanguageCode(forTarget: trimmed)
    }

    /// 应用内部码 → 微软码。服务端其实能接受 zh-CN，但显式映射不依赖它的宽容。
    static func requestLanguageCode(forTarget code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        switch normalized.lowercased() {
        case "zh", "zh-cn", "zh-hans", "zh-sg": return "zh-Hans"
        case "zh-tw", "zh-hk", "zh-hant", "zh-mo": return "zh-Hant"
        case "no", "nb", "nn": return "nb"
        case "tl": return "fil"
        case "pt-br": return "pt"
        case "sr": return "sr-Cyrl"
        case "mn": return "mn-Cyrl"
        default: return normalized
        }
    }

    /// 微软码 → 应用内部码。未知码原样透传，界面只会把它当代码显示。
    static func appLanguageCode(fromMicrosoft code: String) -> String {
        switch code.lowercased() {
        case "zh-hans", "zh": return "zh-CN"
        case "zh-hant", "yue", "lzh": return "zh-TW"
        case "nb", "nn": return "no"
        case "pt-pt", "pt-br": return "pt"
        case "sr-cyrl", "sr-latn": return "sr"
        case "mn-cyrl", "mn-mong": return "mn"
        case "fr-ca": return "fr"
        default: return code
        }
    }

    // MARK: - 响应

    static func parseResponse(_ data: Data, expectedCount: Int) throws -> [TranslationResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              root.count == expectedCount
        else {
            throw EngineError.invalidResponse
        }
        return try root.map { item in
            guard let translations = item["translations"] as? [[String: Any]],
                  let text = translations.first?["text"] as? String
            else {
                throw EngineError.invalidResponse
            }
            let detected = (item["detectedLanguage"] as? [String: Any])?["language"] as? String
            return TranslationResult(
                translatedText: text,
                detectedSourceLanguageCode: detected.map(appLanguageCode(fromMicrosoft:))
            )
        }
    }

    static func mapHTTPError(_ error: HTTPClient.HTTPError) -> Error {
        guard case .badStatus(let code, let body) = error else { return error }
        switch code {
        case 400:
            return EngineError.badRequest(detail: body)
        case 429:
            return EngineError.rateLimited
        default:
            return error
        }
    }

    // MARK: - 切分

    /// 优先在段落 / 空白处切，和 Google 引擎同一套策略。
    static func chunkText(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
            var split = end
            if end < text.endIndex {
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

    /// 把切好的块按字符总量攒成若干请求，减少往返；顺序保持不变。
    static func batchChunks(_ chunks: [String], maxCharacters: Int) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var currentCount = 0
        for chunk in chunks {
            if !current.isEmpty, currentCount + chunk.count > maxCharacters {
                batches.append(current)
                current = []
                currentCount = 0
            }
            current.append(chunk)
            currentCount += chunk.count
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }
}
