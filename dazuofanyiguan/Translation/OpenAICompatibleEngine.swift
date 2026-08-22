import Foundation
import OpenAI

struct OpenAICompatibleEngine: TranslationEngine {
    let title: String = "OpenAI 通用接口"

    enum EngineError: LocalizedError {
        case missingAPIKey
        case missingModel
        case invalidBaseURL(String = "Base URL 无效")
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "请先在设置里填写 API Key"
            case .missingModel:
                return "请先在设置里填写 Model"
            case .invalidBaseURL(let message):
                return message
            case .emptyResponse:
                return "模型没有返回内容"
            }
        }
    }

    struct RateLimitError: LocalizedError {
        let httpStatusCode: Int
        let apiCode: String
        let apiMessage: String

        var errorDescription: String? {
            "请求过多（\(apiCode)）：\(apiMessage)"
        }
    }

    struct ResponsesCompatibilityError: LocalizedError {
        let httpStatusCode: Int
        let responseBody: String

        var errorDescription: String? {
            let detail = responseBody.isEmpty ? "" : "\n服务端返回：\(responseBody)"
            return "Responses 接口已尝试标准和精简请求，仍被服务端拒绝（HTTP \(httpStatusCode)）。该服务可能未完整支持 /responses，或当前模型不支持 Responses；请改用 Chat Completions 或核对服务商文档。\(detail)"
        }
    }

    let baseURL: String
    let apiKey: String?
    let model: String
    let endpointMode: OpenAIEndpointMode
    let onPhaseChange: ((String) -> Void)?
    let onPartialText: (@MainActor (_ text: String, _ replacesPreviousText: Bool) -> Void)?
    let session: URLSession

    init(
        baseURL: String,
        apiKey: String?,
        model: String,
        endpointMode: OpenAIEndpointMode,
        onPhaseChange: ((String) -> Void)?,
        onPartialText: (@MainActor (_ text: String, _ replacesPreviousText: Bool) -> Void)? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.endpointMode = endpointMode
        self.onPhaseChange = onPhaseChange
        self.onPartialText = onPartialText
        self.session = session
    }

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

    private func contentWithCompatibilityFallback(
        transport: OpenAISDKTransport,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        onPartialText: (@MainActor (_ text: String, _ replacesPreviousText: Bool) -> Void)? = nil
    ) async throws -> String {
        do {
            switch endpointMode {
            case .chatCompletions:
                return try await transport.chatContent(
                    model: model,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: temperature
                )
            case .responses:
                if let onPartialText {
                    onPhaseChange?("正在流式接收译文")
                    return try await transport.responsesContentStreaming(
                        model: model,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        temperature: temperature,
                        useMinimalPayload: false,
                        onPartialText: onPartialText
                    )
                }
                return try await transport.responsesContent(
                    model: model,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: temperature,
                    useMinimalPayload: false
                )
            }
        } catch let HTTPClient.HTTPError.badStatus(code, body) where code == 429 {
            throw parseRateLimitError(body: body, httpStatusCode: code)
        } catch OpenAIError.statusError(_, let code) where code == 429 {
            throw RateLimitError(
                httpStatusCode: code,
                apiCode: String(code),
                apiMessage: "请求过多，请稍后重试。"
            )
        } catch let HTTPClient.HTTPError.badStatus(code, _)
            where endpointMode == .responses && (code == 400 || code == 422) {
            return try await contentWithMinimalResponsesPayload(
                transport: transport,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onPartialText: onPartialText
            )
        } catch OpenAIError.statusError(_, let code)
            where endpointMode == .responses && (code == 400 || code == 422) {
            return try await contentWithMinimalResponsesPayload(
                transport: transport,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onPartialText: onPartialText
            )
        }
    }

    private func contentWithMinimalResponsesPayload(
        transport: OpenAISDKTransport,
        systemPrompt: String,
        userPrompt: String,
        onPartialText: (@MainActor (_ text: String, _ replacesPreviousText: Bool) -> Void)?
    ) async throws -> String {
        do {
            if let onPartialText {
                return try await transport.responsesContentStreaming(
                    model: model,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: nil,
                    useMinimalPayload: true,
                    onPartialText: onPartialText
                )
            }
            return try await transport.responsesContent(
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: nil,
                useMinimalPayload: true
            )
        } catch let HTTPClient.HTTPError.badStatus(code, body) where code == 429 {
            throw parseRateLimitError(body: body, httpStatusCode: code)
        } catch OpenAIError.statusError(_, let code) where code == 429 {
            throw RateLimitError(
                httpStatusCode: code,
                apiCode: String(code),
                apiMessage: "请求过多，请稍后重试。"
            )
        } catch let HTTPClient.HTTPError.badStatus(code, body)
            where code == 400 || code == 404 || code == 405 || code == 422 {
            throw ResponsesCompatibilityError(httpStatusCode: code, responseBody: body)
        } catch OpenAIError.statusError(_, let code)
            where code == 400 || code == 404 || code == 405 || code == 422 {
            throw ResponsesCompatibilityError(httpStatusCode: code, responseBody: "")
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

        let url: URL
        do {
            url = try OpenAIEndpointValidator.validatedBaseURL(from: baseURL)
        } catch {
            throw EngineError.invalidBaseURL(error.localizedDescription)
        }

        let transport = try OpenAISDKTransport(baseURL: url, apiKey: apiKey, session: session)

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

        onPhaseChange?("正在请求服务端")
        // 投影器带状态：只解析每个 delta 新增的字符，避免每次都重扫整段累积文本。
        // 回调本身是 @MainActor 串行执行的，这里用一个盒子承载可变状态即可。
        let projectorBox = StreamingProjectorBox()
        let streamingTextHandler: (@MainActor (_ text: String, _ replacesPreviousText: Bool) -> Void)? =
            onPartialText.map { callback in
                { @MainActor accumulatedText, replacesPreviousText in
                    // 新的一条流，或服务端给出的权威全文：增量状态必须先丢掉再重头解析。
                    if replacesPreviousText {
                        projectorBox.session = OpenAIStreamingTranslationProjector.Session()
                    }
                    guard let projection = projectorBox.session.project(
                        from: accumulatedText,
                        isAutoDetect: isAutoDetect
                    ) else { return }
                    // 投影器自己换了候选键时，输出同样不是追加，必须一并告诉下游。
                    callback(
                        projection.text,
                        replacesPreviousText || projection.replacesPreviousText
                    )
                }
            }
        let content = try await contentWithCompatibilityFallback(
            transport: transport,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.2,
            onPartialText: streamingTextHandler
        )
        onPhaseChange?("正在解析响应")
        if content.isEmpty { throw EngineError.emptyResponse }

        if isAutoDetect {
            if let result = OpenAITranslationPayloadParser.parseAutoDetectResult(from: content) {
                return result
            }
        }

        let first = content
        if !isAutoDetect, looksLikeNoOpTranslation(input: text, output: first, targetLanguageCode: targetLanguageCode) {
            let strongerSystemPrompt = "你是一个专业翻译引擎。你必须把输入内容翻译成目标语言（目标语言代码：\(targetLanguageCode)）。只输出译文，不要解释，不要加前后缀。严禁原文回显：如果你发现输出仍是源语言或与输入几乎一致，必须重新翻译直到输出符合目标语言。注意：输入来自 OCR，可能包含噪声，你需要先在心里纠错再翻译。注意：输入里可能包含特殊标记 [[DAZUO_NL]]，它代表换行。你必须原样保留该标记（不要翻译、不要删除、不要新增），并保持其相对位置不变。"
            let strongerUserPrompt = userPrompt

            onPhaseChange?("正在重试翻译")
            let retryContent = try await contentWithCompatibilityFallback(
                transport: transport,
                systemPrompt: strongerSystemPrompt,
                userPrompt: strongerUserPrompt,
                temperature: 0.0,
                onPartialText: streamingTextHandler
            )

            let retryTrimmed = retryContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !retryTrimmed.isEmpty, !looksLikeNoOpTranslation(input: text, output: retryTrimmed, targetLanguageCode: targetLanguageCode) {
                return .init(translatedText: retryTrimmed, detectedSourceLanguageCode: nil)
            }
        }

        return .init(translatedText: first, detectedSourceLanguageCode: nil)
    }
}
