import Foundation

struct TranslationResult {
    let translatedText: String
    let detectedSourceLanguageCode: String?
}

protocol TranslationEngine {
    var title: String { get }

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> TranslationResult
}
