import Foundation

/// 截图 OCR 流程使用的翻译调度，与主窗口 ViewModel 解耦。
@MainActor
enum ScreenshotTranslationService {
    /// 截图翻译送的是 Vision 干净的识别结果，关掉给手动粘贴的 OCR 文本准备的俄语清洗：
    /// 那层清洗会删掉所有汉字，混排段落按俄语翻时里面的中文就没了。
    static func makeRequest(
        text: String,
        engineType: TranslationEngineType,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        openAIBaseURL: String,
        openAIModel: String,
        openAIEndpointMode: OpenAIEndpointMode
    ) -> TranslationRequestContext? {
        TranslationRequestContext.make(
            text: text,
            engineType: engineType,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            openAIEndpointMode: openAIEndpointMode,
            cleansRussianOCRNoise: false
        )
    }

    static func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        settings: AppSettings,
        log: LogStore,
        toast: ToastCenter,
        appleTranslationCoordinator: AppleTranslationCoordinator,
        onPhaseChange: ((String) -> Void)?
    ) async -> Result<String, Error> {
        guard let request = makeRequest(
            text: text,
            engineType: settings.engineType,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            openAIBaseURL: settings.openAIBaseURL,
            openAIModel: settings.openAIModel,
            openAIEndpointMode: settings.openAIEndpointMode
        ) else {
            return .success("")
        }

        let apiKey: String?
        if request.engineType == .openAICompatible {
            do {
                apiKey = try KeychainStore.getString(for: "openAIAPIKey")
            } catch {
                return .failure(error)
            }
        } else {
            apiKey = nil
        }

        do {
            let result = try await FrozenTranslationExecutor.execute(
                request: request,
                apiKey: apiKey,
                appleTranslationCoordinator: appleTranslationCoordinator,
                onAIPhaseChange: onPhaseChange,
                onApplePhaseChange: onPhaseChange,
                onRateLimit: { rateLimit in
                    let base = "请求过多（\(rateLimit.apiCode)）：\(rateLimit.apiMessage)"
                    toast.show(base, style: .warning, duration: 1.0)
                    toast.show("准备重试中（2秒）", style: .info, duration: 1.0)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    toast.show("准备重试中（1秒）", style: .info, duration: 1.0)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            )
            return .success(result.translatedText)
        } catch {
            log.error("截图翻译失败：\(error.localizedDescription)")
            return .failure(error)
        }
    }
}
