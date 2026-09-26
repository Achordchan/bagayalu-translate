import Foundation
import SwiftUI
import Translation

enum AppleTranslationPreparationStatus: Equatable {
    case installed
    case downloadRequired
    case unsupported(message: String)
}

/// 按 worker 代际跟踪「是否有 worker 正在服务请求」。
///
/// 单个布尔位不够：被取消的老 worker 收尾时，不能把新 worker 的忙碌
/// 状态一并清掉（否则顶替判断会误判空闲、走排队唤醒而不是打断）。
/// 只有当前记录在案的那一代 `end` 才真正清空。
struct AppleTranslationServingTracker {
    private var servingGeneration: Int?

    var isServing: Bool { servingGeneration != nil }

    mutating func begin(generation: Int) {
        servingGeneration = generation
    }

    mutating func end(generation: Int) {
        guard servingGeneration == generation else { return }
        servingGeneration = nil
    }
}

/// Apple 本地翻译的协调器：把 `translate()` 请求桥接到 SwiftUI
/// `.translationTask` 送进来的 `TranslationSession`。
///
/// **会话生命周期（1.2.5 的 CPU 飙升事故点）：** `.translationTask` 的 action
/// 返回后，系统侧的翻译会话（宿主进程 + TranslationAPISupportExtension 各一个
/// 隐形窗口）不会立刻回收；旧实现每翻一次就发布新配置让任务重跑一遍，
/// 等于每翻一次就向系统申请一个新会话。会话堆积十几个之后系统翻译扩展会
/// 陷入持续的 SwiftUI 布局循环（实测 90% CPU）。因此本类遵守一条铁律：
/// **action 不随单次翻译结束，会话按语言对常驻复用**（`runSessionWorker`），
/// 只有语言对变化才允许重建会话。
@MainActor
final class AppleTranslationCoordinator: ObservableObject {    private struct TranslationContext {
        let sourceLanguage: Locale.Language?
        let targetLanguage: Locale.Language
        let availabilityStatus: LanguageAvailability.Status
    }

    /// 会话安装决策。独立成纯函数（`installationDecision`）便于单测。
    ///
    /// 携带的 `Configuration` 是该决策下请求要**绑定**的配置：worker
    /// 服务前会校验请求的绑定和自己的配置一致（见 `servePendingRequest`），
    /// 防止语言对切换后，旧 worker 在退出间隙里用旧会话服务新请求。
    enum SessionInstallation: Equatable {
        /// 语言对没变、worker 还在跑：唤醒它服务新请求，不触发任何 SwiftUI 会话重建。
        case reuseLiveSession(TranslationSession.Configuration)
        /// 语言对没变但 worker 已不在：invalidate 当前配置，让任务重跑、重新拿一个会话。
        case rerunInstalledConfiguration(TranslationSession.Configuration)
        /// 首次使用或语言对变了：发布新配置，SwiftUI 会取消旧任务并换新会话。
        case installNewConfiguration(TranslationSession.Configuration)

        /// 该决策下请求应绑定的 Configuration。
        var configuration: TranslationSession.Configuration {
            switch self {
            case .reuseLiveSession(let configuration),
                 .rerunInstalledConfiguration(let configuration),
                 .installNewConfiguration(let configuration):
                return configuration
            }
        }
    }

    private struct PendingRequest {
        let generation: Int
        /// 请求绑定的 Configuration。worker 只服务绑定与自己一致 的请求，
        /// 防止旧语言对的 worker 在退出间隙用错会话服务新请求。
        let configuration: TranslationSession.Configuration
        let text: String
        let shouldPrepareTranslation: Bool
        let onPhaseChange: ((String) -> Void)?
        let onLanguageDownloadStateChange: ((Bool) -> Void)?
    }

    /// 当前安装到 `.translationTask` 的配置。
    ///
    /// 同一语言对只保留这一个值：重复翻译靠唤醒 `runSessionWorker` 完成，
    /// 语言对变化才发布新值。**绝不能每个请求都换一个新值**——那会让
    /// `.translationTask` 为每次翻译各建一个 `TranslationSession`，而旧会话
    /// 从不回收（见类头注释）。
    @Published fileprivate private(set) var sessionConfiguration: TranslationSession.Configuration?

    /// 当前 `.translationTask` worker 的唤醒信号。
    ///
    /// worker 启动时登记、退出时清空。多窗口会挂载多个 worker，只有最新
    /// 登记的接收唤醒，其余空转；并发读到同一个 `pendingRequest` 造成的
    /// 重复翻译会被 `complete(generation:)` 的守卫丢弃，不会重复唤醒
    /// continuation。
    private var workerWake: AsyncStream<Void>.Continuation?
    private var workerGeneration = 0

    /// 是否有 worker 正在服务一个请求（按代际跟踪）。
    ///
    /// 忙时到达的同语言对请求不能只排队唤醒——必须走重跑路径让 SwiftUI
    /// 取消旧任务、打断在途翻译，否则一个卡住的翻译会堵死后续所有请求。
    /// 老的 worker（被顶替后收尾中）无权清除新 worker 的忙碌状态。
    private var servingTracker = AppleTranslationServingTracker()

    private var pendingRequest: PendingRequest?
    private var continuation: CheckedContinuation<TranslationResult, Error>?
    private var generationCounter: Int = 0
    private let languageDetectionService: LanguageDetectionService

    init(languageDetectionService: LanguageDetectionService = .shared) {
        self.languageDetectionService = languageDetectionService
    }

    func preparationStatus(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async -> AppleTranslationPreparationStatus {
        let context = await translationContext(
            text: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )

        switch context.availabilityStatus {
        case .installed:
            return .installed
        case .supported:
            return .downloadRequired
        case .unsupported:
            return .unsupported(
                message: "Apple 本地翻译暂不支持\(LanguagePreset.displayName(for: sourceLanguageCode))到\(LanguagePreset.displayName(for: targetLanguageCode))"
            )
        @unknown default:
            return .downloadRequired
        }
    }

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        onPhaseChange: ((String) -> Void)?,
        onLanguageDownloadStateChange: ((Bool) -> Void)? = nil
    ) async throws -> TranslationResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw AppleTranslationError.nothingToTranslate
        }

        onPhaseChange?("正在检查系统语言支持")
        try Task.checkCancellation()

        let context = await translationContext(
            text: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
        let requiresDownload: Bool
        switch context.availabilityStatus {
        case .installed:
            requiresDownload = false
        case .supported:
            requiresDownload = true
        case .unsupported:
            throw AppleTranslationError.unsupportedLanguagePair(
                source: LanguagePreset.displayName(for: sourceLanguageCode),
                target: LanguagePreset.displayName(for: targetLanguageCode)
            )
        @unknown default:
            requiresDownload = true
        }

        if requiresDownload {
            onPhaseChange?("等待下载系统语言模型")
        } else {
            onPhaseChange?(context.sourceLanguage == nil ? "正在识别原文语言" : "正在启动 Apple 本地翻译")
        }

        generationCounter += 1
        let generation = generationCounter

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                if Task.isCancelled {
                    newContinuation.resume(throwing: CancellationError())
                    return
                }

                cancelPending(throwing: CancellationError())

                // 先定会话安装方式，把请求绑定到它对应的 Configuration 上，
                // 再落地副作用（发布/唤醒）。同一 Actor 内不会被打断，
                // worker 不可能在 pendingRequest 就位前醒来。
                let installation = Self.installationDecision(
                    installed: sessionConfiguration,
                    workerIsIdle: workerWake != nil && !servingTracker.isServing,
                    source: context.sourceLanguage,
                    target: context.targetLanguage
                )

                continuation = newContinuation
                pendingRequest = PendingRequest(
                    generation: generation,
                    configuration: installation.configuration,
                    text: text,
                    shouldPrepareTranslation: context.sourceLanguage != nil,
                    onPhaseChange: onPhaseChange,
                    onLanguageDownloadStateChange: onLanguageDownloadStateChange
                )
                onLanguageDownloadStateChange?(requiresDownload)

                apply(installation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(
                    generation: generation,
                    throwing: CancellationError()
                )
            }
        }
    }

    func cancel() {
        cancelPending(throwing: CancellationError())
    }

    /// 决定如何把一次翻译请求的语言对交给 `.translationTask`。
    ///
    /// 会话复用的分岔点：
    /// - 同语言对、worker **空闲** → 只唤醒，不发布任何变更，零会话重建；
    /// - 同语言对、worker **忙**（正在翻上一个请求）→ 发布 invalidate 过的
    ///   配置触发任务重跑，让 SwiftUI 取消旧任务、**打断在途翻译**——
    ///   这是修复前旧代码的打断语义，忙时顶替若只排队唤醒，一个卡住的
    ///   `prepareTranslation()`/`translate()` 会把后续请求全部堵死。
    ///
    /// invalidate() 不幂等（每次调用产生新值，已实测），所以重跑发布值
    /// 必然不同于已安装值，任务必然重启。
    nonisolated static func installationDecision(
        installed: TranslationSession.Configuration?,
        workerIsIdle: Bool,
        source: Locale.Language?,
        target: Locale.Language
    ) -> SessionInstallation {
        guard let installed,
              installed.source == source,
              installed.target == target
        else {
            return .installNewConfiguration(
                TranslationSession.Configuration(source: source, target: target)
            )
        }
        if workerIsIdle {
            return .reuseLiveSession(installed)
        }
        var refreshed = installed
        refreshed.invalidate()
        return .rerunInstalledConfiguration(refreshed)
    }

    private func apply(_ installation: SessionInstallation) {
        switch installation {
        case .reuseLiveSession:
            workerWake?.yield()
        case .rerunInstalledConfiguration(let configuration),
             .installNewConfiguration(let configuration):
            sessionConfiguration = configuration
        }
    }

    /// worker 退出时的自救决策：挂着的请求绑定与当前安装的配置一致时，
    /// 返回重绑所用的刷新配置（invalidate 后的副本）；不一致或没有请求时
    /// 返回 nil，不动状态——那种请求属于别的路径（如语言对切换触发的
    /// 新任务），自救插手反而添乱。
    ///
    /// **返回的同一个值要同时落到两处**：发布到 `sessionConfiguration`，
    /// 并重绑 `pendingRequest.configuration`。只发布不重绑会挂死——
    /// `Configuration.==` 把 invalidated 状态算进去，新 worker 拿到的
    /// invalidated 值和请求的旧绑定永远不相等，`servePendingRequest`
    /// 的校验过不去。
    nonisolated static func rescueBinding(
        requestConfiguration: TranslationSession.Configuration?,
        installedConfiguration: TranslationSession.Configuration?
    ) -> TranslationSession.Configuration? {
        guard let requestConfiguration,
              let installedConfiguration,
              requestConfiguration == installedConfiguration
        else {
            return nil
        }
        var refreshed = installedConfiguration
        refreshed.invalidate()
        return refreshed
    }

    /// worker 退出后还有未服务请求时的自救：invalidate 当前配置，强制
    /// `.translationTask` 重跑、重新拿一个会话来把它服务掉。
    ///
    /// 语言对切换取消旧 worker 时也会走到这里——此时挂着的请求属于新
    /// 配置，重跑由切换本身触发，这里多 invalidate 一次至多造成一次
    /// 有限的多余任务重跑（会被 generation 守卫丢弃），不会泄漏。
    private func rescueUnservedRequest() {
        guard let request = pendingRequest,
              let refreshed = Self.rescueBinding(
                requestConfiguration: request.configuration,
                installedConfiguration: sessionConfiguration
              )
        else {
            return
        }
        sessionConfiguration = refreshed
        pendingRequest = PendingRequest(
            generation: request.generation,
            configuration: refreshed,
            text: request.text,
            shouldPrepareTranslation: request.shouldPrepareTranslation,
            onPhaseChange: request.onPhaseChange,
            onLanguageDownloadStateChange: request.onLanguageDownloadStateChange
        )
    }

    /// `.translationTask` 的 action 主体：常驻消费翻译请求。
    ///
    /// **这里就是会话复用的实现。** 旧实现每翻一次就让 action 返回，下一次
    /// 翻译再发布新配置触发任务重跑——`.translationTask` 每次重跑都会向系统
    /// 翻译扩展申请一个新 `TranslationSession`（宿主进程和扩展进程各开一个
    /// 隐形窗口），而旧会话从不回收。实测（1.2.5）连续使用选区翻译后两个
    /// 进程各堆积十几个隐形窗口，系统翻译扩展陷入持续的 SwiftUI 布局循环，
    /// CPU 升到 90%，只能重启应用恢复。
    ///
    /// `TranslationSession` 本来就支持在一次任务里翻译多次（系统的 batch API
    /// 就是这么用的），所以改成：任务存活期间会话一直复用。新请求到达时：
    /// worker 空闲则唤醒它服务（零会话重建）；worker 忙则发布 invalidate
    /// 配置触发任务重跑，让 SwiftUI 取消本任务、打断在途翻译（保留修复前
    /// 的打断语义）。语言对变化或视图拆除导致任务被取消时，会话随之由
    /// SwiftUI 回收。
    fileprivate func runSessionWorker(
        using session: TranslationSession,
        configuration: TranslationSession.Configuration?
    ) async {
        guard let configuration else { return }
        workerGeneration += 1
        let generation = workerGeneration
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        workerWake = continuation
        defer {
            if workerGeneration == generation {
                workerWake = nil
            }
        }

        // 首个请求总是先于 worker 就绪：启动时先服务一次挂着的请求。
        await servePendingRequest(
            using: session,
            configuration: configuration,
            workerGeneration: generation
        )

        for await _ in stream {
            if Task.isCancelled { break }
            await servePendingRequest(
                using: session,
                configuration: configuration,
                workerGeneration: generation
            )
        }

        // 退出时还有请求没服务完，说明唤醒恰好落在本 worker 的退出空隙里
        // （或服务到一半被取消）：靠 invalidate 重跑任务把它捡回来。已经有
        // 更新的 worker 在跑时（generation 落后）不用管，新 worker 启动时
        // 会自带一次启动服务。
        if pendingRequest != nil, workerGeneration == generation {
            rescueUnservedRequest()
        }
    }

    private func servePendingRequest(
        using session: TranslationSession,
        configuration: TranslationSession.Configuration,
        workerGeneration: Int
    ) async {
        // 只服务绑定到本 worker 所持 Configuration 的请求。语言对切换后，
        // 旧 worker 可能还带着缓冲的唤醒活着；没有这个校验，它会用旧
        // 语言对的会话去翻新请求，而 generation 守卫拦不住「翻错了」的结果。
        guard let request = pendingRequest, request.configuration == configuration else {
            return
        }
        // 标记在途：期间到达的同语言对请求会走重跑打断，而不是排队等它。
        // 按代际登记——被顶替的老 worker 收尾时清不掉新 worker 的忙碌。
        servingTracker.begin(generation: workerGeneration)
        defer { servingTracker.end(generation: workerGeneration) }

        do {
            if request.shouldPrepareTranslation {
                request.onPhaseChange?("正在准备系统语言模型")
                try await session.prepareTranslation()
                try Task.checkCancellation()
                request.onLanguageDownloadStateChange?(false)
            } else {
                request.onPhaseChange?("正在识别原文语言")
            }

            request.onPhaseChange?("正在使用 Apple 本地翻译")
            let response = try await session.translate(request.text)
            complete(
                generation: request.generation,
                with: .success(
                    TranslationResult(
                        translatedText: response.targetText,
                        detectedSourceLanguageCode: appLanguageCode(from: response.sourceLanguage)
                    )
                )
            )
        } catch {
            complete(
                generation: request.generation,
                with: .failure(friendlyError(from: error))
            )
        }
    }

    private func complete(
        generation: Int,
        with result: Result<TranslationResult, Error>
    ) {
        guard pendingRequest?.generation == generation else {
            return
        }

        let currentContinuation = continuation
        let request = pendingRequest
        continuation = nil
        pendingRequest = nil
        request?.onLanguageDownloadStateChange?(false)

        switch result {
        case .success(let value):
            currentContinuation?.resume(returning: value)
        case .failure(let error):
            currentContinuation?.resume(throwing: error)
        }
    }

    private func cancelPending(throwing error: Error) {
        guard continuation != nil || pendingRequest != nil else {
            return
        }

        let currentContinuation = continuation
        let request = pendingRequest
        continuation = nil
        pendingRequest = nil
        request?.onLanguageDownloadStateChange?(false)
        currentContinuation?.resume(throwing: error)
    }

    private func cancelPending(generation: Int, throwing error: Error) {
        guard pendingRequest?.generation == generation else {
            return
        }
        cancelPending(throwing: error)
    }

    private func translationContext(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async -> TranslationContext {
        let targetLanguage = appleLanguage(for: targetLanguageCode)
        let availability = LanguageAvailability()

        if sourceLanguageCode != LanguagePreset.auto.code {
            let sourceLanguage = appleLanguage(for: sourceLanguageCode)
            let status = await availability.status(
                from: sourceLanguage,
                to: targetLanguage
            )
            return TranslationContext(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                availabilityStatus: status
            )
        }

        let detection = languageDetectionService.detectLanguage(in: text)
        if let detection {
            let detectedLanguage = appleLanguage(for: detection.languageCode)
            let detectedStatus = await availability.status(
                from: detectedLanguage,
                to: targetLanguage
            )
            if detectedStatus != .unsupported {
                return TranslationContext(
                    sourceLanguage: detectedLanguage,
                    targetLanguage: targetLanguage,
                    availabilityStatus: detectedStatus
                )
            }
        }

        // 通用语言识别弃权了。这里**不能**直接把 nil 交出去：
        // 短语上 Apple 自己的自动识别同样会失败，然后弹出
        // 「无法自动检测语言。请选择要翻译的语言。」那个选择器——
        // 在 Mini 气泡里那是个死胡同。先用书写系统兜一层底。
        //
        // **只在弃权时兜底**（`detection == nil`）。识别出来了、但那个语言对
        // 不被支持，是完全另一回事：那时该如实报「不支持」，
        // 而不是换一个「支持的」语言硬翻。比如一段被高置信度识别出的加泰罗尼亚语，
        // 脚本兜底会给出 en（Latin），于是它被当成英语翻译——
        // **用错误的源语言翻出来的结果比一句「不支持」糟得多，因为用户看不出它是错的。**
        if detection == nil, let fallbackCode = LanguageScriptFallback.sourceLanguageCode(
            for: text,
            preferredChineseVariant: targetLanguageCode
        ) {
            let fallbackLanguage = appleLanguage(for: fallbackCode)
            let fallbackStatus = await availability.status(
                from: fallbackLanguage,
                to: targetLanguage
            )
            // 猜出来的语言对本身就不被支持时，说明这个兜底没帮上忙，
            // 继续走原来的自动识别，别用一个必然抛错的语言对把路堵死。
            if fallbackStatus != .unsupported {
                return TranslationContext(
                    sourceLanguage: fallbackLanguage,
                    targetLanguage: targetLanguage,
                    availabilityStatus: fallbackStatus
                )
            }
        }

        let automaticStatus = (try? await availability.status(
            for: text,
            to: targetLanguage
        )) ?? .supported
        return TranslationContext(
            sourceLanguage: nil,
            targetLanguage: targetLanguage,
            availabilityStatus: automaticStatus
        )
    }

    private func appleLanguage(for code: String) -> Locale.Language {
        switch code {
        case "zh-CN":
            return Locale.Language(identifier: "zh-Hans")
        case "zh-TW":
            return Locale.Language(identifier: "zh-Hant")
        default:
            return Locale.Language(identifier: code)
        }
    }

    private func appLanguageCode(from language: Locale.Language) -> String {
        guard let languageCode = language.languageCode?.identifier else {
            return language.minimalIdentifier
        }

        if languageCode == "zh" {
            let script = language.script?.identifier
            let region = language.region?.identifier
            return script == "Hant" || region == "TW" || region == "HK" || region == "MO"
                ? "zh-TW"
                : "zh-CN"
        }

        return languageCode
    }

    private func friendlyError(from error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        if TranslationError.unsupportedSourceLanguage ~= error {
            return AppleTranslationError.unsupportedSourceLanguage
        }
        if TranslationError.unsupportedTargetLanguage ~= error {
            return AppleTranslationError.unsupportedTargetLanguage
        }
        if TranslationError.unsupportedLanguagePairing ~= error {
            return AppleTranslationError.unsupportedLanguagePairing
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return AppleTranslationError.unableToIdentifyLanguage
        }
        if TranslationError.nothingToTranslate ~= error {
            return AppleTranslationError.nothingToTranslate
        }

        return AppleTranslationError.translationFailed(error.localizedDescription)
    }
}

enum AppleTranslationError: LocalizedError {
    case unsupportedLanguagePair(source: String, target: String)
    case unsupportedSourceLanguage
    case unsupportedTargetLanguage
    case unsupportedLanguagePairing
    case unableToIdentifyLanguage
    case nothingToTranslate
    case translationFailed(String)

    /// 这个语言组合本身用不了：换一段同样语言的文字也一样会失败。
    /// 截图翻译据此跳过同语言的其他段，其余错误都只算这一次请求的问题。
    var isLanguagePairUnavailable: Bool {
        switch self {
        case .unsupportedLanguagePair, .unsupportedSourceLanguage,
             .unsupportedTargetLanguage, .unsupportedLanguagePairing:
            return true
        case .unableToIdentifyLanguage, .nothingToTranslate, .translationFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguagePair(let source, let target):
            return "Apple 本地翻译暂不支持\(source)到\(target)"
        case .unsupportedSourceLanguage:
            return "Apple 本地翻译暂不支持当前源语言"
        case .unsupportedTargetLanguage:
            return "Apple 本地翻译暂不支持当前目标语言"
        case .unsupportedLanguagePairing:
            return "Apple 本地翻译暂不支持当前语言组合"
        case .unableToIdentifyLanguage:
            return "Apple 本地翻译无法识别原文语言"
        case .nothingToTranslate:
            return "没有可翻译的内容"
        case .translationFailed(let message):
            return "Apple 本地翻译失败：\(message)"
        }
    }
}

private struct AppleTranslationSessionModifier: ViewModifier {
    @ObservedObject var coordinator: AppleTranslationCoordinator

    func body(content: Content) -> some View {
        // 把触发本次任务运行的 Configuration 捕获进闭包，作为 worker 的
        // 会话身份：请求绑定与它不一致时 worker 拒绝服务（防串台）。
        let configuration = coordinator.sessionConfiguration
        return content.translationTask(configuration) { session in
            await coordinator.runSessionWorker(using: session, configuration: configuration)
        }
    }
}

extension View {
    func appleTranslationSession(using coordinator: AppleTranslationCoordinator) -> some View {
        modifier(AppleTranslationSessionModifier(coordinator: coordinator))
    }
}
