import Foundation
import NaturalLanguage

struct LanguageDetectionResult: Equatable {
    let languageCode: String
    let confidence: Double
}

enum LanguageDetectionPurpose {
    case standard
    case ocr
}

struct LanguageDetectionService {
    static let shared = LanguageDetectionService()

    private let minimumConfidence: Double
    private let minimumConfidenceMargin: Double

    init(
        minimumConfidence: Double = 0.60,
        minimumConfidenceMargin: Double = 0.15
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumConfidenceMargin = minimumConfidenceMargin
    }

    func detectLanguage(
        in text: String,
        purpose: LanguageDetectionPurpose = .standard
    ) -> LanguageDetectionResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasEnoughMeaningfulCharacters(trimmed) else {
            return nil
        }

        if purpose == .ocr, looksLikeRussianOCRArtifacts(trimmed) {
            return LanguageDetectionResult(languageCode: "ru", confidence: 1)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .compactMap { language, confidence -> (code: String, confidence: Double)? in
                guard let code = appLanguageCode(from: language) else {
                    return nil
                }
                return (code, confidence)
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = hypotheses.first,
              best.confidence >= minimumConfidence else {
            return nil
        }

        if hypotheses.count > 1 {
            let confidenceMargin = best.confidence - hypotheses[1].confidence
            guard confidenceMargin >= minimumConfidenceMargin else {
                return nil
            }
        }

        return LanguageDetectionResult(
            languageCode: best.code,
            confidence: best.confidence
        )
    }

    private func hasEnoughMeaningfulCharacters(_ text: String) -> Bool {
        var meaningfulCharacterCount = 0
        var containsCompactScript = false

        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else {
                continue
            }

            meaningfulCharacterCount += 1
            if isCompactScript(scalar) {
                containsCompactScript = true
            }
        }

        return meaningfulCharacterCount >= (containsCompactScript ? 3 : 8)
    }

    private func isCompactScript(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private func appLanguageCode(from language: NLLanguage) -> String? {
        switch language {
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        default:
            let code = language.rawValue
            return LanguagePreset.common.contains(where: { $0.code == code })
                ? code
                : nil
        }
    }

    private func looksLikeRussianOCRArtifacts(_ text: String) -> Bool {
        if text.range(
            of: "\\bnpnBeT\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        if text.range(
            of: "\\b3TO\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }

        let sample = String(text.prefix(220))
        let mappable: Set<Character> = [
            "A", "B", "C", "E", "H", "K", "M", "O", "P", "T", "X", "Y",
            "N", "U", "L", "I",
            "a", "c", "e", "o", "p", "x", "y", "k", "m", "t",
            "n", "u", "l", "i",
            "3", "0"
        ]
        let lettersAndDigits = sample.filter {
            guard let scalar = $0.unicodeScalars.first else {
                return false
            }
            return CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
        }
        guard lettersAndDigits.count >= 24 else {
            return false
        }

        let matchingCount = lettersAndDigits.filter { mappable.contains($0) }.count
        return Double(matchingCount) / Double(lettersAndDigits.count) >= 0.62
    }
}
