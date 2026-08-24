import Foundation

/// 一次候选请求的不可变快照。
struct CandidateTranslationRequest {
    let sourceText: String
    let sourceLanguageCode: String
    let targetLanguageCodes: [String]
    let engineType: TranslationEngineType
    let openAIBaseURL: String
    let openAIModel: String
    let openAIEndpointMode: OpenAIEndpointMode

    var engineFingerprint: String {
        InputAssistCacheKey.engineFingerprint(
            engineType: engineType,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            openAIEndpointMode: openAIEndpointMode
        )
    }

    func cacheKey(targetLanguageCode: String) -> InputAssistCacheKey {
        InputAssistCacheKey(
            sourceText: sourceText,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            engineFingerprint: engineFingerprint
        )
    }
}

/// 多目标语言的并行翻译编排（PRD §18 / §19 / §20 / §21）。
///
/// 每个目标语言一条独立的子任务：谁先回来谁先更新自己那一行，
/// 单条失败也不会拖垮整个浮层。
@MainActor
final class CandidateService {
    private let cache: InputAssistTranslationCacheStore
    private let applePool: InputAssistAppleTranslationPool
    /// Google / OpenAI 用不到 Apple 的 session，但 `FrozenTranslationExecutor`
    /// 的签名要求传一个，给它一个闲置的即可，不必占用池子里的槽位。
    private let idleCoordinator = AppleTranslationCoordinator()

    init(
        cache: InputAssistTranslationCacheStore = .shared,
        applePool: InputAssistAppleTranslationPool
    ) {
        self.cache = cache
        self.applePool = applePool
    }

    /// 启动一次多语言翻译。返回的 Task 取消后所有子任务一起停。
    func start(
        request: CandidateTranslationRequest,
        log: LogStore?,
        onRowUpdate: @escaping @MainActor (_ languageCode: String, _ state: CandidateRowState) -> Void
    ) -> Task<Void, Never> {
        applePool.prepare(slotCount: request.targetLanguageCodes.count)

        return Task { @MainActor [weak self] in
            guard let self else { return }
            let apiKey = self.openAIAPIKeyIfNeeded(for: request, log: log)

            await withTaskGroup(of: Void.self) { group in
                for (index, targetLanguageCode) in request.targetLanguageCodes.enumerated() {
                    group.addTask { @MainActor in
                        await self.translateOne(
                            request: request,
                            targetLanguageCode: targetLanguageCode,
                            slotIndex: index,
                            apiKey: apiKey,
                            allowsLanguagePackDownload: false,
                            log: log,
                            onRowUpdate: onRowUpdate
                        )
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// 单条失败后的重试（PRD §19）。正常结果不提供手动重译。
    func retry(
        request: CandidateTranslationRequest,
        targetLanguageCode: String,
        slotIndex: Int,
        log: LogStore?,
        onRowUpdate: @escaping @MainActor (_ languageCode: String, _ state: CandidateRowState) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            onRowUpdate(targetLanguageCode, .loading)
            let apiKey = self.openAIAPIKeyIfNeeded(for: request, log: log)
            // 重试是用户主动点的：这时候才允许去触发系统的语言包下载（PRD §20）。
            await self.translateOne(
                request: request,
                targetLanguageCode: targetLanguageCode,
                slotIndex: slotIndex,
                apiKey: apiKey,
                allowsLanguagePackDownload: true,
                log: log,
                onRowUpdate: onRowUpdate
            )
        }
    }

    // MARK: - Private

    private func translateOne(
        request: CandidateTranslationRequest,
        targetLanguageCode: String,
        slotIndex: Int,
        apiKey: String?,
        allowsLanguagePackDownload: Bool,
        log: LogStore?,
        onRowUpdate: @escaping @MainActor (_ languageCode: String, _ state: CandidateRowState) -> Void
    ) async {
        let started = Date()
        let cacheKey = request.cacheKey(targetLanguageCode: targetLanguageCode)

        if let cached = await cache.value(for: cacheKey) {
            guard !Task.isCancelled else { return }
            onRowUpdate(targetLanguageCode, .translated(
                text: cached,
                source: .cache,
                latencyMilliseconds: milliseconds(since: started),
                engineTitle: request.engineType.title
            ))
            return
        }

        guard let context = TranslationRequestContext.make(
            text: request.sourceText,
            engineType: request.engineType,
            sourceLanguageCode: request.sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            openAIBaseURL: request.openAIBaseURL,
            openAIModel: request.openAIModel,
            openAIEndpointMode: request.openAIEndpointMode
        ) else {
            onRowUpdate(targetLanguageCode, .failed(message: "没有可翻译的内容"))
            return
        }

        // 每个目标语言必须用自己的 coordinator，否则 Apple 引擎会互相打断（见 pool 的注释）。
        let coordinator: AppleTranslationCoordinator
        if request.engineType == .apple {
            guard let slot = applePool.coordinator(at: slotIndex) else {
                onRowUpdate(targetLanguageCode, .failed(message: "翻译槽位不可用"))
                return
            }
            coordinator = slot
        } else {
            coordinator = idleCoordinator
        }

        if request.engineType == .apple {
            let status = await coordinator.preparationStatus(
                text: request.sourceText,
                sourceLanguageCode: request.sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
            guard !Task.isCancelled else { return }
            switch status {
            case .installed:
                break
            case .downloadRequired:
                // 缺语言包只影响这一行，其它语言继续（PRD §20）。
                // 首次不自动下载：那会弹系统对话框打断用户输入。
                // 用户点了那一行才往下走，`prepareTranslation()` 会引导完成下载。
                guard allowsLanguagePackDownload else {
                    onRowUpdate(targetLanguageCode, .languagePackRequired)
                    return
                }
            case .unsupported(let message):
                onRowUpdate(targetLanguageCode, .failed(message: message))
                return
            }
        }

        do {
            let result = try await FrozenTranslationExecutor.execute(
                request: context,
                apiKey: apiKey,
                appleTranslationCoordinator: coordinator,
                onRateLimit: { rateLimit in
                    log?.warn("Input Assist 遇到限流（\(rateLimit.apiCode)），2 秒后重试")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            )
            guard !Task.isCancelled else { return }

            let trimmed = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                onRowUpdate(targetLanguageCode, .failed(message: "翻译结果为空"))
                return
            }

            await cache.store(result.translatedText, for: cacheKey)
            onRowUpdate(targetLanguageCode, .translated(
                text: result.translatedText,
                source: .network,
                latencyMilliseconds: milliseconds(since: started),
                engineTitle: request.engineType.title
            ))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            onRowUpdate(targetLanguageCode, .failed(message: error.localizedDescription))
        }
    }

    private func openAIAPIKeyIfNeeded(
        for request: CandidateTranslationRequest,
        log: LogStore?
    ) -> String? {
        guard request.engineType == .openAICompatible else { return nil }
        do {
            return try KeychainStore.getString(for: "openAIAPIKey")
        } catch {
            log?.error("Input Assist 读取 Keychain 失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func milliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}
