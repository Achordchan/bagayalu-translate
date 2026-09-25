import Foundation
import NaturalLanguage

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
///
/// 判成目标语言、准备跳过之前，还要看有没有夹着外文：中文段落里的英文要翻，
/// 而且要按那段外文的语言翻——交给引擎自动检测的话，它会把整段认成中文、原样返回。
/// 两种都查：书写系统不同的（中文里的英文），哪怕只有一个词（「请点击 Save 按钮」）也翻——
/// 光看长短分不出按钮名和品牌名，品牌名、型号交给引擎原样保留；同一种书写系统的（英文里的西班牙语）
/// 只能逐句识别语种，句子够长才认得准。
/// 目标是中文、这段也是中文时，只看要不要简繁转换：转成目标字形会变（哪怕简繁混用、只有两个字），就要翻。
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
            let text = blockTexts[index]
            guard hasLetters[index] else { return nil }
            let inference = inferLanguage(
                of: text,
                pageLanguage: overall,
                targetLanguageCode: targetLanguageCode,
                detectLanguage: detectLanguage
            )
            guard let inference, inference.isDecisive || inference.code != targetLanguageCode else {
                // 认不准，交给引擎自动检测。但夹着目标语言的字时，引擎会整段认成目标语言、原样返回，
                // 这时按外文那部分的语言翻（「下载 Save」）。
                if containsNativeLetters(text, targetLanguageCode: targetLanguageCode),
                   let source = sourceOfDifferentScriptText(in: text, targetLanguageCode: targetLanguageCode, detectLanguage: detectLanguage) {
                    return source
                }
                return LanguagePreset.auto.code
            }

            let bothChinese = isChinese(inference.code) && isChinese(targetLanguageCode)
            if bothChinese, let source = variantToConvert(text, to: targetLanguageCode) {
                return source
            }
            guard bothChinese || inference.code == targetLanguageCode else { return inference.code }
            // 已经是目标语言：夹着的外文照样要翻。
            return sourceOfDifferentScriptText(in: text, targetLanguageCode: targetLanguageCode, detectLanguage: detectLanguage)
                ?? sourceOfSameScriptSentences(in: text, targetLanguageCode: targetLanguageCode, detectLanguage: detectLanguage)
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
        // 书写系统能确定语言的前提是整段只用这一种（日文算假名加汉字）：混排的「下载 Save」
        // 不能因为有汉字就整段算中文、再在目标是中文时跳过，里面的英文还没翻。
        let noOtherScripts = !scripts.containsLatin && !scripts.containsCyrillic
            && !scripts.containsArabic && !scripts.containsHebrew && !scripts.containsGreek
            && !scripts.containsThai && !scripts.containsDevanagari && !scripts.containsBengali
            && !scripts.containsTamil && !scripts.containsUnclassifiedLetters
        let chineseOnly = (scripts.containsHan || scripts.containsBopomofo)
            && !scripts.containsKana && !scripts.containsHangul && noOtherScripts
        if scripts.containsKana, !scripts.containsHangul, !scripts.containsBopomofo, noOtherScripts {
            return Inference(code: "ja", isDecisive: true)
        }
        if scripts.containsHangul, !scripts.containsKana, !scripts.containsBopomofo, noOtherScripts {
            return Inference(code: "ko", isDecisive: true)
        }
        if chineseOnly {
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

    /// 夹着的、书写系统和目标语言不同的外文按什么语言翻：先让识别器认，认不出按书写系统猜，
    /// 还猜不出就交给引擎自动检测。没有这样的外文时返回 nil。
    private static func sourceOfDifferentScriptText(
        in text: String,
        targetLanguageCode: String,
        detectLanguage: (String) -> String?
    ) -> String? {
        guard let foreign = foreignText(in: text, targetLanguageCode: targetLanguageCode) else { return nil }
        let language = detectLanguage(foreign) ?? guessLanguage(of: TextScriptPresence(in: foreign), text: foreign)
        guard let language, language != targetLanguageCode else { return LanguagePreset.auto.code }
        return language
    }

    /// 同一种书写系统的外语只能靠识别语种：逐句认，够长的句子认出别的语言就按它翻。都是目标语言时返回 nil。
    /// 目标是中文时，识别器说这句是简体还是繁体不算数：要不要转换已经按字形判断过了。
    private static func sourceOfSameScriptSentences(
        in text: String,
        targetLanguageCode: String,
        detectLanguage: (String) -> String?
    ) -> String? {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var foreignLanguage: String?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSubstantial(sentence),
                  let language = detectLanguage(sentence),
                  language != targetLanguageCode,
                  !(isChinese(language) && isChinese(targetLanguageCode)) else { return true }
            foreignLanguage = language
            return false
        }
        return foreignLanguage
    }

    /// 句子够不够长、识别语种认得准不准：有空格的书写系统 ≥3 个词（每词 ≥2 个字母）或 ≥15 个字母；
    /// 汉字、假名、泰文 ≥4 个字。
    private static func isSubstantial(_ text: String) -> Bool {
        let scripts = TextScriptPresence(in: text)
        let letters = text.filter(\.isLetter).count
        if scripts.containsHan || scripts.containsKana || scripts.containsThai {
            return letters >= 4
        }
        let words = text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 }.count
        return words >= 3 || letters >= 15
    }

    /// 把不属于目标语言书写系统的字母挑出来，词与词之间留一个空格。目标语言的书写系统认不出时返回 nil。
    private static func foreignText(in text: String, targetLanguageCode: String) -> String? {
        guard let isNative = nativeScriptTest(for: targetLanguageCode) else { return nil }
        var result = ""
        for character in text {
            let scripts = TextScriptPresence(in: String(character))
            let cjkSymbol = character.unicodeScalars.allSatisfy { (0x3000...0x303F).contains($0.value) }
            if scripts.containsLetters, !cjkSymbol, !isNative(scripts) {
                result.append(character)
            } else if result.last != " " {
                result.append(" ")
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 有没有目标语言书写系统的字母。
    private static func containsNativeLetters(_ text: String, targetLanguageCode: String) -> Bool {
        guard let isNative = nativeScriptTest(for: targetLanguageCode) else { return false }
        return text.contains { isNative(TextScriptPresence(in: String($0))) }
    }

    /// 目标是中文时要不要做简繁转换：转成目标字形会变，就返回另一种字形（按它翻就是转换）。
    /// 简繁混用的（「发佈」）两种转换都会变，同样要转；简繁同形的转不转都一样。
    private static func variantToConvert(_ text: String, to targetLanguageCode: String) -> String? {
        let (transform, otherVariant) = targetLanguageCode == "zh-TW"
            ? ("Hans-Hant", "zh-CN")
            : ("Hant-Hans", "zh-TW")
        guard let converted = text.applyingTransform(StringTransform(transform), reverse: false),
              converted != text else { return nil }
        return otherVariant
    }

    private static func nativeScriptTest(for languageCode: String) -> ((TextScriptPresence) -> Bool)? {
        switch languageCode {
        case "zh-CN", "zh-TW": return { $0.containsHan || $0.containsBopomofo }
        case "ja": return { $0.containsHan || $0.containsKana }
        case "ko": return { $0.containsHangul || $0.containsHan }
        case "ru", "uk", "bg": return { $0.containsCyrillic }
        case "ar", "fa", "ur": return { $0.containsArabic }
        case "he": return { $0.containsHebrew }
        case "el": return { $0.containsGreek }
        case "th": return { $0.containsThai }
        case "hi": return { $0.containsDevanagari }
        case "bn": return { $0.containsBengali }
        case "ta": return { $0.containsTamil }
        case _ where latinScriptLanguages.contains(languageCode): return { $0.containsLatin }
        default: return nil
        }
    }

    /// 识别器弃权时，按书写系统猜外文的语言。这里是在决定「要不要翻、按什么翻」，
    /// 猜错顶多译得不准；交给引擎自动检测反而会被整段的主语言带偏、原样返回。
    private static func guessLanguage(of scripts: TextScriptPresence, text: String) -> String? {
        if scripts.containsKana { return "ja" }
        if scripts.containsHangul { return "ko" }
        if scripts.containsHan || scripts.containsBopomofo {
            return chineseVariant(of: text, bopomofo: scripts.containsBopomofo) ?? "zh-CN"
        }
        if let language = languageOfUniqueScript(scripts) { return language }
        if scripts.containsArabic { return "ar" }
        if scripts.containsDevanagari { return "hi" }
        if scripts.containsCyrillic { return "ru" }
        if scripts.containsLatin { return "en" }
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
