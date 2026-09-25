import Foundation

/// 截图里每一段该用什么源语言去翻。返回 nil 表示这一段不用翻：
/// 本来就是目标语言，或者根本没有文字（纯数字、符号）。
///
/// 自动检测时逐段判断，而不是整张图定一个语言：截图里中英混排很常见，
/// 中文网页上的英文按钮要翻，中文正文要跳过。短文本上识别器会弃权，这时依次看：
/// 它和整张图的主语言是不是同一种书写系统（法文页面里的「Annuler」按法语翻）；
/// 不是的话看书写系统本身能不能确定语言。
///
/// 只有「有把握」的判断才能决定跳过：识别器认出来的、整页主语言且书写系统对得上的，
/// 以及假名、谚文、汉字这类本身就能确定语言的书写系统。其余只能猜的（拉丁字母猜英语、
/// 西里尔字母猜俄语）一律交给翻译引擎自动检测——整张图只有「Bonjour」、目标是英语时，
/// 把它猜成英语再判成「不用翻」就错了。
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

        let scripts = TextScriptPresence(in: text)
        let chineseOnly = (scripts.containsHan || scripts.containsBopomofo)
            && !scripts.containsKana && !scripts.containsHangul

        if let pageLanguage, isWritten(scripts, inScriptOf: pageLanguage) {
            // 简繁以字形为准：简体页面上的「設置」仍然是繁体，要转换。
            if chineseOnly, isChinese(pageLanguage) {
                return chineseVariant(of: text, bopomofo: scripts.containsBopomofo) ?? pageLanguage
            }
            return pageLanguage
        }

        if scripts.containsKana { return "ja" }
        if scripts.containsHangul { return "ko" }
        if chineseOnly {
            // 字形分得出简繁就以字形为准。简繁同形的字转不转都一样：目标是中文时按目标算
            // （不用转换），否则随便取一种，两种中文译成别的语言没有区别。
            return chineseVariant(of: text, bopomofo: scripts.containsBopomofo)
                ?? (isChinese(targetLanguageCode) ? targetLanguageCode : "zh-CN")
        }
        return nil
    }

    /// 字形能说明是简体还是繁体吗。注音只在繁体里用；简繁同形或两种字形混用时返回 nil。
    /// 用 ICU 的简繁转换试一下：转成繁体会变，说明有简体特有的字；反之亦然。
    private static func chineseVariant(of text: String, bopomofo: Bool) -> String? {
        if bopomofo { return "zh-TW" }
        let hasSimplifiedOnlyCharacters = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
            .map { $0 != text } ?? false
        let hasTraditionalOnlyCharacters = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false)
            .map { $0 != text } ?? false
        switch (hasSimplifiedOnlyCharacters, hasTraditionalOnlyCharacters) {
        case (true, false): return "zh-CN"
        case (false, true): return "zh-TW"
        default: return nil
        }
    }

    private static func isChinese(_ languageCode: String) -> Bool {
        languageCode == "zh-CN" || languageCode == "zh-TW"
    }

    private static let latinScriptLanguages: Set<String> = [
        "en", "it", "fr", "de", "es", "pt", "nl", "sv", "da", "no", "fi",
        "pl", "cs", "hu", "ro", "tr", "vi", "id", "ms", "fil", "sw"
    ]

    /// 这段文字用的书写系统和这门语言对得上吗。认不出的书写系统一律算对不上：
    /// 宁可交给引擎自动检测，也不要把阿拉伯文页面上的希腊文当成阿拉伯文。
    private static func isWritten(_ scripts: TextScriptPresence, inScriptOf languageCode: String) -> Bool {
        let otherScripts = scripts.containsArabic || scripts.containsHebrew || scripts.containsGreek
            || scripts.containsThai || scripts.containsDevanagari || scripts.containsBengali
            || scripts.containsTamil

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
                && !scripts.containsHangul && !scripts.containsCyrillic && !otherScripts
        case "ar", "fa", "ur":
            return writtenOnlyIn(scripts, scripts.containsArabic)
        case "he":
            return writtenOnlyIn(scripts, scripts.containsHebrew)
        case "el":
            return writtenOnlyIn(scripts, scripts.containsGreek)
        case "th":
            return writtenOnlyIn(scripts, scripts.containsThai)
        case "hi":
            return writtenOnlyIn(scripts, scripts.containsDevanagari)
        case "bn":
            return writtenOnlyIn(scripts, scripts.containsBengali)
        case "ta":
            return writtenOnlyIn(scripts, scripts.containsTamil)
        default:
            return false
        }
    }

    /// 字母只来自这一种书写系统。
    private static func writtenOnlyIn(_ scripts: TextScriptPresence, _ containsScript: Bool) -> Bool {
        let flags = [
            scripts.containsLatin, scripts.containsCyrillic, scripts.containsHan, scripts.containsKana,
            scripts.containsHangul, scripts.containsBopomofo, scripts.containsArabic, scripts.containsHebrew,
            scripts.containsGreek, scripts.containsThai, scripts.containsDevanagari, scripts.containsBengali,
            scripts.containsTamil
        ]
        return containsScript && flags.filter { $0 }.count == 1 && !scripts.containsUnclassifiedLetters
    }
}
