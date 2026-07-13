import Foundation
import SwiftUI
import Translation

enum AppleTranslationPreparationStatus: Equatable {
    case installed
    case downloadRequired
    case unsupported(message: String)
}

@MainActor
final class AppleTranslationCoordinator: ObservableObject {
    private struct TranslationContext {
        let sourceLanguage: Locale.Language?
        let targetLanguage: Locale.Language
        let availabilityStatus: LanguageAvailability.Status
    }

    fileprivate struct SessionRequest {
        let configuration: TranslationSession.Configuration?
        let generation: Int
    }

    private struct PendingRequest {
        let generation: Int
        let text: String
        let shouldPrepareTranslation: Bool
        let onPhaseChange: ((String) -> Void)?
        let onLanguageDownloadStateChange: ((Bool) -> Void)?
    }

    @Published fileprivate private(set) var sessionRequest = SessionRequest(
        configuration: nil,
        generation: 0
    )

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

                continuation = newContinuation
                pendingRequest = PendingRequest(
                    generation: generation,
                    text: text,
                    shouldPrepareTranslation: context.sourceLanguage != nil,
                    onPhaseChange: onPhaseChange,
                    onLanguageDownloadStateChange: onLanguageDownloadStateChange
                )
                onLanguageDownloadStateChange?(requiresDownload)

                var configuration = TranslationSession.Configuration(
                    source: context.sourceLanguage,
                    target: context.targetLanguage
                )
                if sessionRequest.configuration == configuration {
                    configuration.invalidate()
                }
                sessionRequest = SessionRequest(
                    configuration: configuration,
                    generation: generation
                )
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

    fileprivate func performTranslation(
        using session: TranslationSession,
        generation: Int
    ) async {
        guard let request = pendingRequest, request.generation == generation else {
            return
        }

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
                generation: generation,
                with: .success(
                    TranslationResult(
                        translatedText: response.targetText,
                        detectedSourceLanguageCode: appLanguageCode(from: response.sourceLanguage)
                    )
                )
            )
        } catch {
            complete(
                generation: generation,
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

        if let detection = languageDetectionService.detectLanguage(in: text) {
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

private enum AppleTranslationError: LocalizedError {
    case unsupportedLanguagePair(source: String, target: String)
    case unsupportedSourceLanguage
    case unsupportedTargetLanguage
    case unsupportedLanguagePairing
    case unableToIdentifyLanguage
    case nothingToTranslate
    case translationFailed(String)

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
        let request = coordinator.sessionRequest
        content.translationTask(request.configuration) { session in
            await coordinator.performTranslation(
                using: session,
                generation: request.generation
            )
        }
    }
}

extension View {
    func appleTranslationSession(using coordinator: AppleTranslationCoordinator) -> some View {
        modifier(AppleTranslationSessionModifier(coordinator: coordinator))
    }
}
