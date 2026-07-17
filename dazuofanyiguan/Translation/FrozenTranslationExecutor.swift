import Foundation

/// 基于不可变请求上下文的共享翻译执行器。
@MainActor
enum FrozenTranslationExecutor {
    static func makeEngine(
        for request: TranslationRequestContext,
        apiKey: String?,
        onPhaseChange: ((String) -> Void)? = nil
    ) -> TranslationEngine? {
        switch request.engineType {
        case .apple:
            return nil
        case .google:
            return GoogleTranslateEngine()
        case .openAICompatible:
            return OpenAICompatibleEngine(
                baseURL: request.openAIBaseURL,
                apiKey: apiKey,
                model: request.openAIModel,
                endpointMode: request.openAIEndpointMode,
                onPhaseChange: onPhaseChange
            )
        }
    }

    static func execute(
        request: TranslationRequestContext,
        apiKey: String?,
        appleTranslationCoordinator: AppleTranslationCoordinator,
        onAIPhaseChange: ((String) -> Void)? = nil,
        onApplePhaseChange: ((String) -> Void)? = nil,
        onLanguageDownloadStateChange: ((Bool) -> Void)? = nil,
        onRateLimit: ((OpenAICompatibleEngine.RateLimitError) async throws -> Void)? = nil
    ) async throws -> TranslationResult {
        let engine = makeEngine(
            for: request,
            apiKey: apiKey,
            onPhaseChange: onAIPhaseChange
        )

        let result: TranslationResult
        if request.engineType == .apple {
            result = try await appleTranslationCoordinator.translate(
                text: request.preparedText,
                sourceLanguageCode: request.sourceLanguageCode,
                targetLanguageCode: request.targetLanguageCode,
                onPhaseChange: onApplePhaseChange,
                onLanguageDownloadStateChange: onLanguageDownloadStateChange
            )
        } else if let engine {
            result = try await translateWithRateLimitRetry(
                engine: engine,
                text: request.preparedText,
                sourceLanguageCode: request.sourceLanguageCode,
                targetLanguageCode: request.targetLanguageCode,
                onRateLimit: onRateLimit
            )
        } else {
            throw NSError(
                domain: "FrozenTranslationExecutor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "翻译引擎未正确初始化"]
            )
        }

        let translatedText = request.shouldRestoreNewlines
            ? TranslationRequestContext.restoreNewlines(from: result.translatedText)
            : result.translatedText
        return TranslationResult(
            translatedText: translatedText,
            detectedSourceLanguageCode: result.detectedSourceLanguageCode
        )
    }

    static func translateWithRateLimitRetry(
        engine: TranslationEngine,
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        onRateLimit: ((OpenAICompatibleEngine.RateLimitError) async throws -> Void)? = nil
    ) async throws -> TranslationResult {
        do {
            return try await engine.translate(
                text: text,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        } catch {
            guard let rateLimit = error as? OpenAICompatibleEngine.RateLimitError else {
                throw error
            }
            if let onRateLimit {
                try await onRateLimit(rateLimit)
            } else {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if Task.isCancelled { throw error }
            return try await engine.translate(
                text: text,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        }
    }
}
