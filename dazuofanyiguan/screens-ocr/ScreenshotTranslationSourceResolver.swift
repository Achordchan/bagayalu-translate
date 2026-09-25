import Foundation

/// 截图里每一段该用什么源语言去翻。返回 nil 表示这一段不用翻：
/// 本来就是目标语言，或者根本没有文字（纯数字、符号）。
///
/// 自动检测时逐段判断，而不是整张图定一个语言：截图里中英混排很常见，
/// 中文网页上的英文按钮要翻，中文正文要跳过。短文本上识别器会弃权，这时依次看：
/// 它和整张图的主语言是不是同一种书写系统（法文页面里的「Annuler」按法语翻）；
/// 不是的话按书写系统兜底。
///
/// 只有「有把握」的判断才能决定跳过：识别器认出来的、或整页主语言且书写系统对得上的，
/// 以及汉字、假名、谚文这类本身就能确定语言的书写系统。拉丁字母、西里尔字母只能猜
/// （兜底默认英语、俄语），猜出来的交给翻译引擎自动检测——整张图只有「Bonjour」、
/// 目标是英语时，把它猜成英语再判成「不用翻」就错了。
enum ScreenshotTranslationSourceResolver {
    static func resolve(
        blockTexts: [String],
        sourceLanguageCode: String,
        targetLanguageCode: String,
        detectLanguage: (String) -> String? = {
            LanguageDetectionService.shared.detectLanguage(in: $0)?.languageCode
        }
    ) -> [String?] {
        let hasLetters = blockTexts.map { TextScriptPresence(in: $0).containsLetters }

        guard sourceLanguageCode == LanguagePreset.auto.code else {
            let code: String? = sourceLanguageCode == targetLanguageCode ? nil : sourceLanguageCode
            return hasLetters.map { $0 ? code : nil }
        }

        let overall = detectLanguage(blockTexts.joined(separator: "\n"))
        return blockTexts.indices.map { index in
            guard hasLetters[index] else { return nil }
            guard let code = confidentLanguage(
                of: blockTexts[index],
                pageLanguage: overall,
                targetLanguageCode: targetLanguageCode,
                detectLanguage: detectLanguage
            ) else {
                return LanguagePreset.auto.code
            }
            return code == targetLanguageCode ? nil : code
        }
    }

    /// 有把握时返回语言代码；只能靠猜时返回 nil。
    private static func confidentLanguage(
        of text: String,
        pageLanguage: String?,
        targetLanguageCode: String,
        detectLanguage: (String) -> String?
    ) -> String? {
        if let detected = detectLanguage(text) {
            return detected
        }
        if let pageLanguage, isWritten(text, inScriptOf: pageLanguage) {
            return pageLanguage
        }
        let scripts = TextScriptPresence(in: text)
        guard scripts.containsKana || scripts.containsHangul
            || scripts.containsHan || scripts.containsBopomofo else {
            return nil
        }
        return LanguageScriptFallback.sourceLanguageCode(
            for: text,
            preferredChineseVariant: targetLanguageCode
        )
    }

    private static let latinScriptLanguages: Set<String> = [
        "en", "it", "fr", "de", "es", "pt", "nl", "sv", "da", "no", "fi",
        "pl", "cs", "hu", "ro", "tr", "vi", "id", "ms", "fil", "sw"
    ]

    /// 这段文字用的书写系统和这门语言对得上吗。
    private static func isWritten(_ text: String, inScriptOf languageCode: String) -> Bool {
        let scripts = TextScriptPresence(in: text)
        let hasRecognizedScript = scripts.containsLatin || scripts.containsCyrillic
            || scripts.containsHan || scripts.containsKana
            || scripts.containsHangul || scripts.containsBopomofo

        switch languageCode {
        case "ja":
            return scripts.containsKana || (scripts.containsHan && !scripts.containsHangul)
        case "zh-CN", "zh-TW":
            return (scripts.containsHan || scripts.containsBopomofo)
                && !scripts.containsKana && !scripts.containsHangul
        case "ko":
            return scripts.containsHangul
        case "ru", "uk", "bg":
            return scripts.containsCyrillic
        case _ where latinScriptLanguages.contains(languageCode):
            return scripts.containsLatin
                && !scripts.containsHan && !scripts.containsKana
                && !scripts.containsHangul && !scripts.containsCyrillic
        default:
            // 阿拉伯文、泰文、希腊文等 TextScriptPresence 认不出的书写系统：
            // 有字母、又不属于任何认得出的书写系统，才算对得上。
            return scripts.containsLetters && !hasRecognizedScript
        }
    }
}
