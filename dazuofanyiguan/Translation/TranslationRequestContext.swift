import Foundation

/// 单次翻译请求的不可变快照，避免异步执行期间读到用户中途改动的设置。
struct TranslationRequestContext: Equatable {
    let engineType: TranslationEngineType
    let sourceLanguageCode: String
    let targetLanguageCode: String
    let openAIBaseURL: String
    let openAIModel: String
    let openAIEndpointMode: OpenAIEndpointMode
    let preparedText: String
    let rawText: String

    static let newlineMarker = "[[DAZUO_NL]]"

    var engineTitle: String { engineType.title }
    var isUsingAI: Bool { engineType == .openAICompatible }
    var shouldRestoreNewlines: Bool { engineType != .apple }

    /// 从当前设置冻结一次翻译请求；文本为空时返回 nil。
    static func make(
        text: String,
        engineType: TranslationEngineType,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        openAIBaseURL: String,
        openAIModel: String,
        openAIEndpointMode: OpenAIEndpointMode
    ) -> TranslationRequestContext? {
        let rawText = text
        let normalizedText = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let preparedText = engineType == .apple
            ? normalizedText
            : normalizedText.replacingOccurrences(of: "\n", with: " \(newlineMarker) ")
        guard !preparedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return TranslationRequestContext(
            engineType: engineType,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            openAIEndpointMode: openAIEndpointMode,
            preparedText: preparedText,
            rawText: rawText
        )
    }

    @MainActor
    static func make(
        text: String,
        settings: AppSettings,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) -> TranslationRequestContext? {
        make(
            text: text,
            engineType: settings.engineType,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            openAIBaseURL: settings.openAIBaseURL,
            openAIModel: settings.openAIModel,
            openAIEndpointMode: settings.openAIEndpointMode
        )
    }

    static func restoreNewlines(from text: String) -> String {
        text
            .replacingOccurrences(of: " \(newlineMarker) ", with: "\n")
            .replacingOccurrences(of: newlineMarker, with: "\n")
    }
}
