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

        let scripts = ScriptPresence(in: trimmedText)
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
        scripts: ScriptPresence,
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
        scripts: ScriptPresence,
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

private struct ScriptPresence {
    private(set) var containsLetters = false
    private(set) var containsHan = false
    private(set) var containsKana = false
    private(set) var containsHangul = false
    private(set) var containsBopomofo = false

    init(in text: String) {
        for scalar in text.unicodeScalars {
            containsLetters = containsLetters || CharacterSet.letters.contains(scalar)
            containsHan = containsHan || Self.isHan(scalar)
            containsKana = containsKana || Self.isKana(scalar)
            containsHangul = containsHangul || Self.isHangul(scalar)
            containsBopomofo = containsBopomofo || Self.isBopomofo(scalar)
        }
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,
             0x31F0...0x31FF,
             0xFF65...0xFF9F:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,
             0x3130...0x318F,
             0xA960...0xA97F,
             0xAC00...0xD7AF,
             0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }

    private static func isBopomofo(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3100...0x312F,
             0x31A0...0x31BF:
            return true
        default:
            return false
        }
    }
}
