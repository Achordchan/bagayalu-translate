import AppKit
import Foundation

@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var outputText: String = ""

    @Published var isTranslating: Bool = false
    @Published private(set) var translationToken: Int = 0
    @Published var lastErrorMessage: String?
    @Published var detectedSourceLanguageCode: String?

    @Published private(set) var isUsingAI: Bool = false
    @Published private(set) var activeAIModelName: String?
    @Published private(set) var estimatedAITokenCount: Int?
    @Published private(set) var aiRequestPhase: String?

    @Published private(set) var lastTranslationDurationMs: Int?
    @Published private(set) var lastAIModelName: String?
    @Published private(set) var lastAIEstimatedTokens: Int?

    private var debounceTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?

    private var translationTokenCounter: Int = 0

    private let http = HTTPClient()

    private let newlineMarker: String = "[[DAZUO_NL]]"

    func scheduleTranslate(settings: AppSettings, log: LogStore, toast: ToastCenter) {
        debounceTask?.cancel()
        let text = inputText

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelTranslation(clearInput: false)
            outputText = ""
            return
        }

        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            if Task.isCancelled { return }
            await translateNow(settings: settings, log: log, toast: toast)
        }
    }

    private func translateWithRateLimitRetry(
        engine: TranslationEngine,
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        settings: AppSettings,
        log: LogStore,
        toast: ToastCenter
    ) async throws -> TranslationResult {
        do {
            return try await engine.translate(
                text: text,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        } catch {
            guard let rl = error as? OpenAICompatibleEngine.RateLimitError else {
                throw error
            }

            let base = "请求过多（\(rl.apiCode)）：\(rl.apiMessage)"
            lastErrorMessage = base
            log.warn("翻译遇到限流：\(base)，2秒后重试")

            toast.show(base, style: .warning, duration: 1.0)
            toast.show("准备重试中（2秒）", style: .info, duration: 1.0)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { throw error }

            toast.show("准备重试中（1秒）", style: .info, duration: 1.0)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { throw error }

            // 真正开始重试（仅一次）。
            log.info("限流倒计时结束，开始重试")
            return try await engine.translate(
                text: text,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
        }
    }

    func translateNow(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        translateTask?.cancel()

        let rawText = inputText
        let normalizedText = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputText = ""
            detectedSourceLanguageCode = nil
            lastErrorMessage = nil
            isTranslating = false
            isUsingAI = false
            activeAIModelName = nil
            estimatedAITokenCount = nil
            aiRequestPhase = nil
            return
        }
        let text = normalizedText.replacingOccurrences(of: "\n", with: " \(newlineMarker) ")
        let sl = settings.sourceLanguageCode
        let tl = settings.targetLanguageCode

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputText = ""
            detectedSourceLanguageCode = nil
            estimatedAITokenCount = nil
            aiRequestPhase = nil
            return
        }

        translationTokenCounter += 1
        translationToken = translationTokenCounter
        let token = translationToken

        lastTranslationDurationMs = nil

        outputText = ""
        detectedSourceLanguageCode = nil
        isTranslating = true
        lastErrorMessage = nil
        isUsingAI = settings.engineType == .openAICompatible
        let modelName = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        activeAIModelName = settings.engineType == .openAICompatible ? (modelName.isEmpty ? nil : modelName) : nil

        if isUsingAI {
            estimatedAITokenCount = estimateTotalTokensForAI(text: text, targetLanguageCode: tl, model: modelName)
            aiRequestPhase = "正在准备请求"
        } else {
            estimatedAITokenCount = nil
            aiRequestPhase = nil
        }

        let engine: TranslationEngine
        switch settings.engineType {
        case .google:
            engine = GoogleTranslateEngine()
        case .openAICompatible:
            let key: String?
            do {
                key = try KeychainStore.getString(for: "openAIAPIKey")
            } catch {
                log.error("读取 Keychain 失败：\(error.localizedDescription)")
                key = nil
            }
            engine = OpenAICompatibleEngine(
                baseURL: settings.openAIBaseURL,
                apiKey: key,
                model: settings.openAIModel,
                endpointMode: settings.openAIEndpointMode,
                onPhaseChange: { [weak self] phase in
                    Task { @MainActor in
                        self?.aiRequestPhase = phase
                    }
                }
            )
        }

        if let estimated = estimatedAITokenCount {
            log.info("开始翻译（引擎：\(engine.title) sl=\(sl) tl=\(tl) 字数=\(rawText.count) 预计Token=\(estimated)）")
        } else {
            log.info("开始翻译（引擎：\(engine.title) sl=\(sl) tl=\(tl) 字数=\(rawText.count)）")
        }
        let start = Date()

        translateTask = Task { @MainActor in
            do {
                if self.isUsingAI {
                    self.aiRequestPhase = "正在等待服务端响应"
                }
                let result = try await translateWithRateLimitRetry(
                    engine: engine,
                    text: text,
                    sourceLanguageCode: sl,
                    targetLanguageCode: tl,
                    settings: settings,
                    log: log,
                    toast: toast
                )
                if Task.isCancelled { return }
                if token != translationToken { return }
                outputText = restoreNewlines(from: result.translatedText)
                detectedSourceLanguageCode = result.detectedSourceLanguageCode
                let cost = Int(Date().timeIntervalSince(start) * 1000)
                lastTranslationDurationMs = cost
                if self.isUsingAI {
                    lastAIModelName = self.activeAIModelName
                    lastAIEstimatedTokens = self.estimatedAITokenCount
                } else {
                    lastAIModelName = nil
                    lastAIEstimatedTokens = nil
                }
                log.info("翻译完成（\(cost)ms）")
            } catch {
                if Task.isCancelled { return }
                if token != translationToken { return }
                lastErrorMessage = error.localizedDescription
                log.error("翻译失败：\(error.localizedDescription)")
                toast.show(error.localizedDescription, style: .error)
            }

            if token == translationToken {
                isTranslating = false
                isUsingAI = false
                activeAIModelName = nil
                estimatedAITokenCount = nil
                aiRequestPhase = nil
            }
        }
    }

    private func restoreNewlines(from text: String) -> String {
        text
            .replacingOccurrences(of: " \(newlineMarker) ", with: "\n")
            .replacingOccurrences(of: newlineMarker, with: "\n")
    }

    private func estimateTotalTokensForAI(text: String, targetLanguageCode: String, model: String) -> Int {
        let systemPrompt = "你是一个专业翻译引擎。只输出翻译后的文本，不要解释，不要加前后缀。"
        let userPrompt = "把下面的内容翻译成目标语言（目标语言代码：\(targetLanguageCode)）。\n\n\(text)"

        let promptTokens = estimateTokens(for: systemPrompt) + estimateTokens(for: userPrompt)
        let completionTokens = max(64, Int(Double(promptTokens) * 0.55))
        return promptTokens + completionTokens
    }

    private func estimateTokens(for text: String) -> Int {
        let cjkCount = text.unicodeScalars.reduce(into: 0) { acc, scalar in
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) {
                acc += 1
            }
        }
        let total = text.count
        let other = max(0, total - cjkCount)
        return cjkCount + Int(ceil(Double(other) / 4.0))
    }

    func cancelTranslation(clearInput: Bool) {
        debounceTask?.cancel()
        translateTask?.cancel()
        translateTask = nil

        translationTokenCounter += 1
        translationToken = translationTokenCounter

        isTranslating = false
        isUsingAI = false
        activeAIModelName = nil
        aiRequestPhase = nil
        lastErrorMessage = nil
        detectedSourceLanguageCode = nil
        lastTranslationDurationMs = nil
        lastAIModelName = nil
        lastAIEstimatedTokens = nil

        if clearInput {
            inputText = ""
            outputText = ""
        }
    }

    func retryTranslateNow(settings: AppSettings, log: LogStore, toast: ToastCenter) {
        cancelTranslation(clearInput: false)
        Task { @MainActor in
            await translateNow(settings: settings, log: log, toast: toast)
        }
    }

    func reverseTranslate(settings: AppSettings, log: LogStore, toast: ToastCenter) {
        let previousOutput = outputText

        let trimmedOutput = previousOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty {
            toast.show("还没有译文，无法反向翻译", style: .warning)
            return
        }

        let detected = detectedSourceLanguageCode
        let source = settings.sourceLanguageCode
        let target = settings.targetLanguageCode

        inputText = previousOutput
        outputText = ""

        settings.sourceLanguageCode = target

        if source != LanguagePreset.auto.code {
            settings.targetLanguageCode = source
        } else if let detected, !detected.isEmpty {
            settings.targetLanguageCode = detected
        } else {
            settings.targetLanguageCode = "en"
        }

        scheduleTranslate(settings: settings, log: log, toast: toast)
    }

    func copyOutput(toast: ToastCenter) {
        let text = outputText
        guard !text.isEmpty else {
            toast.show("没有可复制的内容", style: .warning)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast.show("已复制到剪贴板", style: .success)
    }

    func applyExternalText(_ text: String, settings: AppSettings, log: LogStore, toast: ToastCenter) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        inputText = trimmed
        scheduleTranslate(settings: settings, log: log, toast: toast)
    }
}
