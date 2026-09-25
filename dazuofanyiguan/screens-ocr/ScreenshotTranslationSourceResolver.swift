import Foundation

/// 截图里每一段该用什么源语言去翻。返回 nil 表示这一段不用翻：
/// 本来就是目标语言，或者根本没有文字（纯数字、符号）。
///
/// 自动检测时逐段判断，而不是整张图定一个语言：截图里中英混排很常见，
/// 中文网页上的英文按钮要翻，中文正文要跳过。短文本上识别器会弃权，这时再看书写系统和整页主语言。
///
/// 判断分两档，只有「能确定」的才能决定跳过：
/// - 能确定：识别器认出来的；书写系统本身就能确定语言的（汉字按字形分简繁、假名、谚文、
///   希腊文、希伯来文、泰文、孟加拉文、泰米尔文）。
/// - 只是提示：拉丁、西里尔、阿拉伯字母这类多种语言共用的书写系统，和整页主语言对得上时，
///   拿整页主语言当翻译的源语言；但它恰好等于目标语言时不能据此跳过——
///   英文页面上单独的法文「Bonjour」也是拉丁字母。这种情况交给翻译引擎自动检测。
/// 两档都不沾的（只有一个「Bonjour」、没有整页语言可参考）同样交给引擎自动检测。
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
            guard let inference = inferLanguage(
                of: blockTexts[index],
                pageLanguage: overall,
                targetLanguageCode: targetLanguageCode,
                detectLanguage: detectLanguage
            ) else {
                return LanguagePreset.auto.code
            }
            if inference.code == targetLanguageCode {
                return inference.isDecisive ? nil : LanguagePreset.auto.code
            }
            return inference.code
        }
    }

    private struct Inference {
        let code: String
        /// 能确定（可以据此跳过），还是只是翻译提示。
        let isDecisive: Bool
    }

    private static func inferLanguage(
        of text: String,
        pageLanguage: String?,
        targetLanguageCode: String,
        detectLanguage: (String) -> String?
    ) -> Inference? {
        if let detected = detectLanguage(text) {
            return Inference(code: detected, isDecisive: true)
        }

        let scripts = TextScriptPresence(in: text)
        if scripts.containsKana {
            return Inference(code: "ja", isDecisive: true)
        }
        if scripts.containsHangul {
            return Inference(code: "ko", isDecisive: true)
        }
        if scripts.containsHan || scripts.containsBopomofo {
            // 日文页面里只有汉字的标签按日文算。
            if pageLanguage == "ja", !scripts.containsBopomofo {
                return Inference(code: "ja", isDecisive: true)
            }
            // 简繁以字形为准（简体页面上的「設置」仍然是繁体，要转换）。简繁同形的字转不转都一样：
            // 沿用整页的中文变体，其次按目标语言算（不用转换），都不是中文就随便取一种。
            let variant = chineseVariant(of: text, bopomofo: scripts.containsBopomofo)
                ?? pageLanguage.flatMap { isChinese($0) ? $0 : nil }
                ?? (isChinese(targetLanguageCode) ? targetLanguageCode : "zh-CN")
            return Inference(code: variant, isDecisive: true)
        }
        if let language = languageOfUniqueScript(scripts) {
            return Inference(code: language, isDecisive: true)
        }
        if let pageLanguage, isWritten(scripts, inScriptOf: pageLanguage) {
            return Inference(code: pageLanguage, isDecisive: false)
        }
        return nil
    }

    /// 只有一门语言在用的书写系统。
    private static func languageOfUniqueScript(_ scripts: TextScriptPresence) -> String? {
        if writtenOnlyIn(scripts, scripts.containsGreek) { return "el" }
        if writtenOnlyIn(scripts, scripts.containsHebrew) { return "he" }
        if writtenOnlyIn(scripts, scripts.containsThai) { return "th" }
        if writtenOnlyIn(scripts, scripts.containsBengali) { return "bn" }
        if writtenOnlyIn(scripts, scripts.containsTamil) { return "ta" }
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

    /// 这段文字和整页主语言用的是不是同一种多语言共用的书写系统（拉丁、西里尔、阿拉伯、天城文）。
    /// 认不出的书写系统一律算对不上：宁可交给引擎自动检测，也不要把阿拉伯文页面上的希腊文当成阿拉伯文。
    private static func isWritten(_ scripts: TextScriptPresence, inScriptOf languageCode: String) -> Bool {
        switch languageCode {
        case _ where latinScriptLanguages.contains(languageCode):
            return writtenOnlyIn(scripts, scripts.containsLatin, allowingUnclassifiedLetters: true)
        case "ru", "uk", "bg":
            return writtenOnlyIn(scripts, scripts.containsCyrillic)
        case "ar", "fa", "ur":
            return writtenOnlyIn(scripts, scripts.containsArabic)
        case "hi":
            return writtenOnlyIn(scripts, scripts.containsDevanagari)
        default:
            return false
        }
    }

    /// 字母只来自这一种书写系统。拉丁文放宽「其他字母」：连字、全角拉丁字母这类
    /// 不在拉丁区间里的字符也常见，不能因为它们就不认。
    private static func writtenOnlyIn(
        _ scripts: TextScriptPresence,
        _ containsScript: Bool,
        allowingUnclassifiedLetters: Bool = false
    ) -> Bool {
        let flags = [
            scripts.containsLatin, scripts.containsCyrillic, scripts.containsHan, scripts.containsKana,
            scripts.containsHangul, scripts.containsBopomofo, scripts.containsArabic, scripts.containsHebrew,
            scripts.containsGreek, scripts.containsThai, scripts.containsDevanagari, scripts.containsBengali,
            scripts.containsTamil
        ]
        return containsScript && flags.filter { $0 }.count == 1
            && (allowingUnclassifiedLetters || !scripts.containsUnclassifiedLetters)
    }
}
