import Foundation

struct TranslationLanguagePair: Equatable {
    let sourceLanguageCode: String
    let targetLanguageCode: String
}

enum MiniTranslationDirectionResolver {
    static func resolve(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        languageDetectionService: LanguageDetectionService = .shared
    ) -> TranslationLanguagePair {
        let configuredPair = TranslationLanguagePair(
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return configuredPair
        }

        let scripts = TextScriptPresence(in: trimmedText)
        let detectedLanguageCode = languageDetectionService
            .detectLanguage(in: trimmedText)?
            .languageCode

        if isChineseText(
            scripts: scripts,
            detectedLanguageCode: detectedLanguageCode
        ) {
            return TranslationLanguagePair(
                sourceLanguageCode: chineseSourceLanguageCode(
                    detectedLanguageCode: detectedLanguageCode
                ),
                targetLanguageCode: reverseTargetLanguageCode(
                    configuredSourceLanguageCode: sourceLanguageCode
                )
            )
        }

        guard scripts.containsLetters || detectedLanguageCode != nil else {
            return configuredPair
        }

        return TranslationLanguagePair(
            sourceLanguageCode: nonChineseSourceLanguageCode(
                scripts: scripts,
                detectedLanguageCode: detectedLanguageCode
            ),
            targetLanguageCode: preferredChineseTargetLanguageCode(
                configuredTargetLanguageCode: targetLanguageCode
            )
        )
    }

    private static func isChineseText(
        scripts: TextScriptPresence,
        detectedLanguageCode: String?
    ) -> Bool {
        if scripts.containsKana || scripts.containsHangul {
            return false
        }
        if let detectedLanguageCode {
            return isChineseLanguageCode(detectedLanguageCode)
        }
        return scripts.containsHan || scripts.containsBopomofo
    }

    private static func chineseSourceLanguageCode(
        detectedLanguageCode: String?
    ) -> String {
        guard let detectedLanguageCode,
              isChineseLanguageCode(detectedLanguageCode) else {
            return LanguagePreset.auto.code
        }
        return detectedLanguageCode
    }

    private static func nonChineseSourceLanguageCode(
        scripts: TextScriptPresence,
        detectedLanguageCode: String?
    ) -> String {
        if scripts.containsKana {
            return "ja"
        }
        if scripts.containsHangul {
            return "ko"
        }
        if let detectedLanguageCode,
           !isChineseLanguageCode(detectedLanguageCode) {
            return detectedLanguageCode
        }
        return LanguagePreset.auto.code
    }

    private static func reverseTargetLanguageCode(
        configuredSourceLanguageCode: String
    ) -> String {
        let normalizedSource = configuredSourceLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty,
              normalizedSource.caseInsensitiveCompare(LanguagePreset.auto.code) != .orderedSame,
              normalizedSource.caseInsensitiveCompare("und") != .orderedSame,
              !isChineseLanguageCode(normalizedSource) else {
            return "en"
        }
        return normalizedSource
    }

    private static func preferredChineseTargetLanguageCode(
        configuredTargetLanguageCode: String
    ) -> String {
        let normalizedTarget = configuredTargetLanguageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return isChineseLanguageCode(normalizedTarget) ? normalizedTarget : "zh-CN"
    }

    private static func isChineseLanguageCode(_ code: String) -> Bool {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalizedCode == "zh" || normalizedCode.hasPrefix("zh-")
    }
}
