import Foundation

/// 截图里每一段该用什么源语言去翻。返回 nil 表示这一段不用翻：
/// 本来就是目标语言，或者根本没有文字（纯数字、符号）。
///
/// 自动检测时逐段判断，而不是整张图定一个语言：截图里中英混排很常见，
/// 中文网页上的英文按钮要翻，中文正文要跳过。短文本上识别器会弃权，这时依次看：
/// 它和整张图的主语言是不是同一种书写系统（法文页面里的「Annuler」按法语翻）；
/// 不是的话按书写系统兜底（中文页面里的「Sign in」按英语翻）。
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
            let text = blockTexts[index]
            let code = detectLanguage(text)
                ?? overall.flatMap { isWritten(text, inScriptOf: $0) ? $0 : nil }
                ?? LanguageScriptFallback.sourceLanguageCode(
                    for: text,
                    preferredChineseVariant: targetLanguageCode
                )
                ?? overall
                ?? LanguagePreset.auto.code
            return code == targetLanguageCode ? nil : code
        }
    }

    /// 这段文字用的书写系统和这门语言对得上吗。
    /// 阿拉伯文、泰文等 TextScriptPresence 不认识的书写系统一律算对不上，交给后面的兜底。
    private static func isWritten(_ text: String, inScriptOf languageCode: String) -> Bool {
        let scripts = TextScriptPresence(in: text)
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
        default:
            return scripts.containsLatin
                && !scripts.containsHan && !scripts.containsKana
                && !scripts.containsHangul && !scripts.containsCyrillic
        }
    }
}
