import Foundation

struct OpenAICompatibleEngine: TranslationEngine {
    let title: String = "OpenAI 通用接口"

    enum EngineError: LocalizedError {
        case missingAPIKey
        case missingModel
        case invalidBaseURL
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "请先在设置里填写 API Key"
            case .missingModel:
                return "请先在设置里填写 Model"
            case .invalidBaseURL:
                return "Base URL 无效"
            case .emptyResponse:
                return "模型没有返回内容"
            }
        }
    }

    private let http = HTTPClient()

    struct RateLimitError: LocalizedError {
        let httpStatusCode: Int
        let apiCode: String
        let apiMessage: String

        var errorDescription: String? {
            "请求过多（\(apiCode)）：\(apiMessage)"
        }
    }

    let baseURL: String
    let apiKey: String?
    let model: String
    let endpointMode: OpenAIEndpointMode
    let onPhaseChange: ((String) -> Void)?

    private func parseRateLimitError(body: String, httpStatusCode: Int) -> RateLimitError {
        struct Payload: Decodable {
            struct Inner: Decodable {
                let code: String?
                let message: String?
            }
            let error: Inner?
        }

        if let data = body.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           let e = decoded.error {
            let code = (e.code?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? String(httpStatusCode)
            let msg = (e.message?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "请求过多，请稍后重试。"
            return RateLimitError(httpStatusCode: httpStatusCode, apiCode: code, apiMessage: msg)
        }

        let fallbackBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = fallbackBody.isEmpty ? "请求过多，请稍后重试。" : fallbackBody
        return RateLimitError(httpStatusCode: httpStatusCode, apiCode: String(httpStatusCode), apiMessage: msg)
    }

    private func dataHandlingRateLimit(for request: URLRequest) async throws -> Data {
        do {
            return try await http.data(for: request)
        } catch {
            if case let HTTPClient.HTTPError.badStatus(code, body) = error, code == 429 {
                throw parseRateLimitError(body: body, httpStatusCode: code)
            }
            throw error
        }
    }

    private func normalizedForCompare(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsCyrillic(_ s: String) -> Bool {
        s.range(of: "[\\u0400-\\u04FF]", options: .regularExpression) != nil
    }

    private func looksLikeNoOpTranslation(input: String, output: String, targetLanguageCode: String) -> Bool {
        let a = normalizedForCompare(input)
        let b = normalizedForCompare(output)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }

        let target = targetLanguageCode.lowercased()
        if target != "ru" && target != "uk" {
            if containsCyrillic(b) {
                return true
            }
        }
        return false
    }

    private func looksLikeRussianOCRArtifacts(_ text: String) -> Bool {
        let t = text

        // 如果已经有西里尔字母，本身就很像俄语。
        if containsCyrillic(t) { return true }

        // 典型固定错。
        if t.range(of: "\\bnpnBeT\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if t.range(of: "\\b3TO\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }

        // 更严格的判断：必须出现 OCR 常见特征（数字夹在词里 / 大小写混乱 / 全大写短词）。
        // 避免把正常英文单词（如 conventional）误判成“俄语伪拉丁”。
        let parts = t.components(separatedBy: .whitespacesAndNewlines)
        if parts.isEmpty { return false }

        let mapKeys: Set<Character> = [
            "A", "B", "C", "E", "H", "K", "M", "O", "P", "T", "X", "Y",
            "N", "U", "L", "I",
            "a", "c", "e", "o", "p", "x", "y", "k", "m", "t",
            "n", "u", "l", "i",
            "3", "0"
        ]

        func counts(for s: String) -> (upper: Int, lower: Int, digit: Int) {
            var u = 0
            var l = 0
            var d = 0
            for ch in s {
                guard let scalar = ch.unicodeScalars.first else { continue }
                if CharacterSet.uppercaseLetters.contains(scalar) { u += 1 }
                else if CharacterSet.lowercaseLetters.contains(scalar) { l += 1 }
                else if CharacterSet.decimalDigits.contains(scalar) { d += 1 }
            }
            return (u, l, d)
        }

        func isSuspiciousToken(_ token: String) -> Bool {
            if token.contains("[[DAZUO_NL]]") { return false }
            if token.contains("/") || token.contains("\\") || token.contains("-") { return false }

            let core = token.trimmingCharacters(in: .punctuationCharacters)
            if core.count < 4 { return false }

            let c = counts(for: core)
            let hasDigit = c.digit > 0
            let isMixedCase = c.upper >= 2 && c.lower >= 1
            let isAllUpperShort = c.lower == 0 && c.upper == core.count && core.count <= 8

            let chars = Array(core)
            let hit = chars.filter { mapKeys.contains($0) }.count
            if hit < 3 { return false }
            let ratio = Double(hit) / Double(chars.count)

            return ratio >= 0.7 && (hasDigit || isMixedCase || isAllUpperShort)
        }

        let suspiciousCount = parts.prefix(60).filter { isSuspiciousToken($0) }.count
        return suspiciousCount >= 2
    }

    private func fixRussianOCRNoise(_ text: String) -> String {
        // 仅做“高把握”的替换：把西里尔字母常见误识别的拉丁/数字映射回去。
        // 目标：让翻译引擎吃到更干净的俄文，而不是“伪拉丁”。
        // 注意：保留 [[DAZUO_NL]]；跳过包含 /、\、- 的 token，避免误伤 CE/ISO/EAC、BOB-LIFT 等。
        var t = text

        // 俄语 OCR 偶发混入其它字符（例如汉字），先移除。
        t = t.replacingOccurrences(of: "[\\p{Han}]", with: "", options: .regularExpression)

        // 常见固定错：
        t = t.replacingOccurrences(of: "npnBeT", with: "Привет", options: [.caseInsensitive, .regularExpression])
        t = t.replacingOccurrences(of: "3TO", with: "Это", options: [.caseInsensitive, .regularExpression])

        let map: [Character: Character] = [
            "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К", "M": "М", "O": "О", "P": "Р", "T": "Т", "X": "Х", "Y": "У",
            "N": "П", "U": "И", "L": "Л", "I": "И",
            "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х", "y": "у", "k": "к", "m": "м", "t": "т",
            "n": "п", "u": "и", "l": "л", "i": "и",
            "3": "Э", "0": "О"
        ]

        func counts(for s: String) -> (upper: Int, lower: Int, digit: Int) {
            var u = 0
            var l = 0
            var d = 0
            for ch in s {
                guard let scalar = ch.unicodeScalars.first else { continue }
                if CharacterSet.uppercaseLetters.contains(scalar) { u += 1 }
                else if CharacterSet.lowercaseLetters.contains(scalar) { l += 1 }
                else if CharacterSet.decimalDigits.contains(scalar) { d += 1 }
            }
            return (u, l, d)
        }

        func looksLikeSuspectToken(_ token: String) -> Bool {
            if token.contains("[[DAZUO_NL]]") { return false }
            if token.contains("/") || token.contains("\\") || token.contains("-") { return false }
            let core = token.trimmingCharacters(in: .punctuationCharacters)
            if core.count < 4 { return false }

            // 必须具备 OCR 噪声特征，否则不要动（避免把正常英文小写单词映射成西里尔字母）。
            let c = counts(for: core)
            let hasDigit = c.digit > 0
            let isMixedCase = c.upper >= 2 && c.lower >= 1
            let isAllUpperShort = c.lower == 0 && c.upper == core.count && core.count <= 8
            if !(hasDigit || isMixedCase || isAllUpperShort) { return false }

            let chars = Array(core)
            let m = chars.filter { map[$0] != nil }.count
            if m < 3 { return false }
            return Double(m) / Double(chars.count) >= 0.7
        }

        func normalizeCyrillicCasing(_ s: String) -> String {
            if s.count < 4 { return s }
            if s.range(of: "[А-Яа-я]", options: .regularExpression) == nil { return s }
            let lower = s.lowercased()
            guard let first = lower.first else { return s }
            return String(first).uppercased() + lower.dropFirst()
        }

        let parts = t.components(separatedBy: .whitespacesAndNewlines)
        if parts.isEmpty { return normalizedForCompare(t) }

        let mapped = parts.map { token -> String in
            if !looksLikeSuspectToken(token) { return token }
            let mappedCore = String(token.map { map[$0] ?? $0 })
            return normalizeCyrillicCasing(mappedCore)
        }

        return normalizedForCompare(mapped.joined(separator: " "))
    }

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> TranslationResult {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.missingAPIKey
        }

        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EngineError.missingModel
        }

        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw EngineError.invalidBaseURL
        }

        let endpoint: URL
        switch endpointMode {
        case .chatCompletions:
            endpoint = url.appendingPathComponent("chat/completions")
        case .responses:
            endpoint = url.appendingPathComponent("responses")
        }

        let isAutoDetect = sourceLanguageCode == "auto"

        // 在 OpenAI 侧做一层“俄语 OCR 噪声”清洗：
        // - 截图 OCR 会经过 Vision 后处理；
        // - 但用户手动粘贴 OCR 文本到输入框时，没有这层清洗。
        // 这里统一做一下，让两条路径表现一致。
        var preparedText = text
        if sourceLanguageCode == "ru" || (!isAutoDetect && sourceLanguageCode.hasPrefix("ru-")) {
            preparedText = fixRussianOCRNoise(preparedText)
        } else if isAutoDetect, looksLikeRussianOCRArtifacts(preparedText) {
            preparedText = fixRussianOCRNoise(preparedText)
        }

        let systemPrompt: String
        let userPrompt: String
        if isAutoDetect {
            systemPrompt = "你是一个专业翻译引擎。你需要先识别输入文本的语言，然后把它翻译成目标语言。翻译应忠实原意、表达自然，避免生硬逐字直译（例如反问语气应使用目标语言的常见表达）。注意：输入来自 OCR，可能包含识别噪声（例如重音符号丢失、标点误识别，西班牙语倒问号 ¿ 可能被识别为 i）。你需要先在心里根据上下文做合理纠错，再进行翻译。只输出严格 JSON，不要解释，不要加前后缀，不要代码块。JSON 必须是单行（不要换行）。JSON 结构必须为：{\"detectedSourceLanguageCode\":\"xx\",\"translatedText\":\"...\"}。其中 detectedSourceLanguageCode 使用常见语言代码（例如 en, ja, ko, ru, zh-CN）。如果无法判断请返回 und。注意：输入里可能包含特殊标记 [[DAZUO_NL]]，它代表换行。你必须原样保留该标记（不要翻译、不要删除、不要新增），并保持其相对位置不变。"
            userPrompt = "把下面的内容翻译成目标语言（目标语言代码：\(targetLanguageCode)）。\n\n\(preparedText)"
        } else {
            systemPrompt = "你是一个专业翻译引擎。源语言代码：\(sourceLanguageCode)。你必须把输入内容翻译成目标语言（目标语言代码：\(targetLanguageCode)）。只输出翻译后的文本，不要解释，不要加前后缀。翻译应忠实原意、表达自然，避免生硬逐字直译（例如反问语气应使用目标语言的常见表达）。注意：输入来自 OCR，可能包含识别噪声（例如俄语西里尔字母被误识别成拉丁字母/数字；重音符号丢失；标点误识别）。你需要先在心里根据上下文做合理纠错，再进行翻译。注意：输入里可能包含特殊标记 [[DAZUO_NL]]，它代表换行。你必须原样保留该标记（不要翻译、不要删除、不要新增），并保持其相对位置不变。"
            userPrompt = "把下面的内容翻译成目标语言（目标语言代码：\(targetLanguageCode)）。\n\n\(preparedText)"
        }

        let body: [String: Any]
        switch endpointMode {
        case .chatCompletions:
            body = [
                "model": model,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
        case .responses:
            body = [
                "model": model,
                "temperature": 0.2,
                "input": "\(systemPrompt)\n\n\(userPrompt)"
            ]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        onPhaseChange?("正在请求服务端")
        let data = try await dataHandlingRateLimit(for: request)
        onPhaseChange?("正在解析响应")

        let decoder = JSONDecoder()

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

        let content: String
        switch endpointMode {
        case .chatCompletions:
            let decoded = try decoder.decode(ChatCompletionsResponse.self, from: data)
            content = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .responses:
            let decoded = try decoder.decode(ResponsesResponse.self, from: data)
            if let text = decoded.output_text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                content = text
            } else {
                content = decoded.output?.first?.content?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }

        if content.isEmpty { throw EngineError.emptyResponse }

        if isAutoDetect {
            func extractJSONObjectString(from raw: String) -> String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("```") {
                    let lines = trimmed
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                    if lines.count >= 2 {
                        let withoutFirst = lines.dropFirst().joined(separator: "\n")
                        if let lastFence = withoutFirst.range(of: "```", options: .backwards) {
                            return String(withoutFirst[..<lastFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
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

            struct AutoDetectPayload {
                let detectedSourceLanguageCode: String?
                let translatedText: String?
            }

            func decodeAutoDetectPayload(from jsonString: String) -> AutoDetectPayload? {
                guard let data = jsonString.data(using: .utf8) else { return nil }
                do {
                    let container = try JSONDecoder().decode([String: String?].self, from: data)
                    let detected = container["detectedSourceLanguageCode"] ?? container["detected_source_language_code"] ?? container["detected_source"] ?? nil
                    let translated = container["translatedText"] ?? container["translated_text"] ?? container["translation"] ?? nil
                    return AutoDetectPayload(detectedSourceLanguageCode: detected ?? nil, translatedText: translated ?? nil)
                } catch {
                    do {
                        let decoder = JSONDecoder()
                        let keyed = try decoder.decode([String: String].self, from: data)
                        let detected = keyed["detectedSourceLanguageCode"] ?? keyed["detected_source_language_code"] ?? keyed["detected_source"]
                        let translated = keyed["translatedText"] ?? keyed["translated_text"] ?? keyed["translation"]
                        return AutoDetectPayload(detectedSourceLanguageCode: detected, translatedText: translated)
                    } catch {
                        do {
                            let decoder = JSONDecoder()
                            let root = try decoder.decode([String: AnyDecodable].self, from: data)
                            let detected = root["detectedSourceLanguageCode"]?.stringValue ?? root["detected_source_language_code"]?.stringValue ?? root["detected_source"]?.stringValue
                            let translated = root["translatedText"]?.stringValue ?? root["translated_text"]?.stringValue ?? root["translation"]?.stringValue
                            return AutoDetectPayload(detectedSourceLanguageCode: detected, translatedText: translated)
                        } catch {
                            return nil
                        }
                    }
                }
            }

            struct AnyDecodable: Decodable {
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

            let jsonString = extractJSONObjectString(from: content)
            if let payload = decodeAutoDetectPayload(from: jsonString),
               let translated = payload.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translated.isEmpty {
                let detected = payload.detectedSourceLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .init(translatedText: translated, detectedSourceLanguageCode: detected)
            }
        }

        let first = content
        if !isAutoDetect, looksLikeNoOpTranslation(input: text, output: first, targetLanguageCode: targetLanguageCode) {
            let strongerSystemPrompt = "你是一个专业翻译引擎。你必须把输入内容翻译成目标语言（目标语言代码：\(targetLanguageCode)）。只输出译文，不要解释，不要加前后缀。严禁原文回显：如果你发现输出仍是源语言或与输入几乎一致，必须重新翻译直到输出符合目标语言。注意：输入来自 OCR，可能包含噪声，你需要先在心里纠错再翻译。注意：输入里可能包含特殊标记 [[DAZUO_NL]]，它代表换行。你必须原样保留该标记（不要翻译、不要删除、不要新增），并保持其相对位置不变。"
            let strongerUserPrompt = userPrompt

            let retryBody: [String: Any]
            switch endpointMode {
            case .chatCompletions:
                retryBody = [
                    "model": model,
                    "temperature": 0.0,
                    "messages": [
                        ["role": "system", "content": strongerSystemPrompt],
                        ["role": "user", "content": strongerUserPrompt]
                    ]
                ]
            case .responses:
                retryBody = [
                    "model": model,
                    "temperature": 0.0,
                    "input": "\(strongerSystemPrompt)\n\n\(strongerUserPrompt)"
                ]
            }

            var retryRequest = URLRequest(url: endpoint)
            retryRequest.httpMethod = "POST"
            retryRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            retryRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            retryRequest.httpBody = try JSONSerialization.data(withJSONObject: retryBody)

            onPhaseChange?("正在重试翻译")
            let retryData = try await dataHandlingRateLimit(for: retryRequest)

            let retryContent: String
            switch endpointMode {
            case .chatCompletions:
                let decoded = try decoder.decode(ChatCompletionsResponse.self, from: retryData)
                retryContent = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            case .responses:
                let decoded = try decoder.decode(ResponsesResponse.self, from: retryData)
                if let text = decoded.output_text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    retryContent = text
                } else {
                    retryContent = decoded.output?.first?.content?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            }

            let retryTrimmed = retryContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !retryTrimmed.isEmpty, !looksLikeNoOpTranslation(input: text, output: retryTrimmed, targetLanguageCode: targetLanguageCode) {
                return .init(translatedText: retryTrimmed, detectedSourceLanguageCode: nil)
            }
        }

        return .init(translatedText: first, detectedSourceLanguageCode: nil)
    }
}
