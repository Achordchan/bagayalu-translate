import Foundation

/// Mini 等外部入口使用的独立翻译执行器。
/// 不读写主窗口 TranslatorViewModel 的 input/output，避免覆盖用户草稿。
@MainActor
enum StandaloneTranslationRunner {
    static func translate(
        text: String,
        settings: AppSettings,
        log: LogStore,
        languagePair: TranslationLanguagePair,
        appleTranslationCoordinator: AppleTranslationCoordinator
    ) async throws -> TranslationResult {
        guard let request = TranslationRequestContext.make(
            text: text,
            settings: settings,
            sourceLanguageCode: languagePair.sourceLanguageCode,
            targetLanguageCode: languagePair.targetLanguageCode
        ) else {
            return TranslationResult(translatedText: "", detectedSourceLanguageCode: nil)
        }

        log.info(
            "Mini 独立翻译开始（引擎：\(request.engineTitle) sl=\(request.sourceLanguageCode) tl=\(request.targetLanguageCode) 字数=\(request.rawText.count)）"
        )
        let start = Date()

        let apiKey: String?
        if request.engineType == .openAICompatible {
            do {
                apiKey = try KeychainStore.getString(for: "openAIAPIKey")
            } catch {
                log.error("读取 Keychain 失败：\(error.localizedDescription)")
                apiKey = nil
            }
        } else {
            apiKey = nil
        }

        let result = try await FrozenTranslationExecutor.execute(
            request: request,
            apiKey: apiKey,
            appleTranslationCoordinator: appleTranslationCoordinator,
            onRateLimit: { rateLimit in
                let base = "请求过多（\(rateLimit.apiCode)）：\(rateLimit.apiMessage)"
                log.warn("Mini 翻译遇到限流：\(base)，2秒后重试")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                log.info("Mini 限流倒计时结束，开始重试")
            }
        )

        let cost = Int(Date().timeIntervalSince(start) * 1000)
        log.info("Mini 独立翻译完成（\(cost)ms）")
        return result
    }
}
