import Foundation
import Testing
@testable import 大佐翻译官v1

/// 短语触发「无法自动检测语言」的回归。
///
/// 背景见 `LanguageScriptFallback` 的文档注释：`NLLanguageRecognizer` 在短语上几乎必然弃权，
/// 弃权之后我们原本会把 `sourceLanguage: nil` 交给 Apple Translation，
/// 而它自己也认不出，于是弹出语言选择器。
struct LanguageScriptFallbackTests {

    @Test func shortLatinTokensFallBackToEnglishInsteadOfNothing() {
        // 这几个就是实际会踩到的：识别器给它们的第一名分别是
        // cs:0.21 / en:0.33 / en:0.31，全在 0.60 阈值之下。
        for text in ["TestHost", "Settings", "Download", "hello world"] {
            #expect(LanguageScriptFallback.sourceLanguageCode(for: text) == "en")
        }
    }

    @Test func shortChineseIsDecidedByScriptNotByTheRecognizer() {
        // "设置" 只有 2 个字，过不了识别器的字数门槛，
        // 但汉字这件事本身已经足够确定它不是英文。
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "设置") == "zh-CN")
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "你好") == "zh-CN")
    }

    @Test func kanaAndHangulWinOverHan() {
        // 日文正文里混着汉字，韩文里也可能出现汉字。
        // 先判汉字的话这两种都会被认成中文，所以顺序不能反。
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "こんにちは") == "ja")
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "日本語のテスト") == "ja")
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "안녕하세요") == "ko")
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "한자漢字") == "ko")
    }

    @Test func cyrillicFallsBackToRussian() {
        // "Привет" 识别器给的是 bg:0.53 ru:0.42——差值不到 0.15，同样弃权。
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "Привет") == "ru")
    }

    @Test func chineseVariantFollowsTheTargetWhenTheTargetIsChinese() {
        // 目标是繁体时，兜底的源语言也用繁体，别把简繁混起来。
        #expect(
            LanguageScriptFallback.sourceLanguageCode(for: "設置", preferredChineseVariant: "zh-TW")
                == "zh-TW"
        )
        // 目标不是中文时这个参数用不上，回到简体默认值。
        #expect(
            LanguageScriptFallback.sourceLanguageCode(for: "设置", preferredChineseVariant: "en")
                == "zh-CN"
        )
    }

    @Test func textWithoutAnyScriptSignalStaysUnknown() {
        // 纯数字 / 符号：脚本也给不出信息，老老实实返回 nil，
        // 让调用方走原来的自动识别，不要瞎猜一个语言出来。
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "12345") == nil)
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "!!! ??? ...") == nil)
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "") == nil)
    }

    // MARK: - 整条链（截图里那个 case）

    @Test func shortEnglishPhraseEndsUpAsEnglishToChinese() {
        // Mini 的方向解析仍然给 auto——它没有能力判断，也不该假装有。
        let pair = MiniTranslationDirectionResolver.resolve(
            text: "TestHost",
            sourceLanguageCode: LanguagePreset.auto.code,
            targetLanguageCode: "en"
        )
        #expect(pair.sourceLanguageCode == LanguagePreset.auto.code)
        #expect(pair.targetLanguageCode == "zh-CN")

        // 补上兜底之后，交给 Apple 的是 en → zh-CN，而不是 nil → zh-CN。
        #expect(
            LanguageScriptFallback.sourceLanguageCode(
                for: "TestHost",
                preferredChineseVariant: pair.targetLanguageCode
            ) == "en"
        )
    }

    @Test func shortChinesePhraseEndsUpAsChineseToEnglish() {
        let pair = MiniTranslationDirectionResolver.resolve(
            text: "设置",
            sourceLanguageCode: LanguagePreset.auto.code,
            targetLanguageCode: "en"
        )
        #expect(pair.sourceLanguageCode == LanguagePreset.auto.code)
        #expect(pair.targetLanguageCode == "en")

        #expect(
            LanguageScriptFallback.sourceLanguageCode(
                for: "设置",
                preferredChineseVariant: pair.targetLanguageCode
            ) == "zh-CN"
        )
    }

    // MARK: - 气泡页脚

    @Test func footerHeightIsAddedOnceForBothNotices() {
        // 「智能翻译识别已介入」和「原文 英语」共用页脚同一行，高度只该加一次。
        let state = MiniTranslationBubbleState.result("译文")
        let bare = MiniTranslationLayout.contentSize(for: state)
        let notice = MiniTranslationLayout.contentSize(
            for: state, showsSmartDirectionNotice: true
        )
        let language = MiniTranslationLayout.contentSize(
            for: state, showsDetectedLanguage: true
        )
        let both = MiniTranslationLayout.contentSize(
            for: state, showsSmartDirectionNotice: true, showsDetectedLanguage: true
        )
        #expect(notice.height > bare.height)
        #expect(language.height == notice.height)
        #expect(both.height == notice.height)
    }

    @Test func scriptPresenceDetectsTheNewlyAddedScripts() {
        let cyrillic = TextScriptPresence(in: "Привет")
        #expect(cyrillic.containsCyrillic)
        #expect(!cyrillic.containsLatin)

        let latin = TextScriptPresence(in: "Café")
        #expect(latin.containsLatin)
        #expect(!latin.containsCyrillic)

        // 抽成共享类型之后，原有判断必须逐字保持不变。
        let mixed = TextScriptPresence(in: "日本語のテスト")
        #expect(mixed.containsKana)
        #expect(mixed.containsHan)
        #expect(!mixed.containsHangul)
    }
}
