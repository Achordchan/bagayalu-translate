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

    @Test func bopomofoIsATraditionalSignalOnItsOwn() {
        // 注音符号自己就说明了简繁：台湾用注音，大陆用拼音。
        // 和汉字合并处理的话，目标是英文时会退到 zh-CN——
        // 等于把一段明确的繁体信号交成简体，Apple 可能因此选错语言模型。
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "ㄋㄧˇㄏㄠˇ") == "zh-TW")
        // 注音混着汉字（台湾的注音标注读物）也一样按繁体。
        #expect(LanguageScriptFallback.sourceLanguageCode(for: "你好ㄋㄧˇ") == "zh-TW")
        // 目标语言不再影响它——猜没有必要。
        #expect(
            LanguageScriptFallback.sourceLanguageCode(
                for: "ㄋㄧˇㄏㄠˇ",
                preferredChineseVariant: "zh-CN"
            ) == "zh-TW"
        )
        // 纯汉字仍然分不出简繁，继续参考目标语言。
        #expect(
            LanguageScriptFallback.sourceLanguageCode(
                for: "设置",
                preferredChineseVariant: "zh-TW"
            ) == "zh-TW"
        )
    }

    @Test func selectionPolicyAgreesWithTheFallbackOnBopomofo() {
        // 两处判定必须一致，否则同一段文字在选区翻译和 Apple 引擎里会被认成不同语言。
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "ㄋㄧˇㄏㄠˇ",
                detectedLanguageCode: nil
            ) == "zh-TW"
        )
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

    // MARK: - 兜底的适用边界（Codex review #5 第九轮）

    @Test func theFallbackOnlyCoversAbstention() {
        // 兜底的契约是"识别器弃权时才用"。识别出来了、但那个语言对不被支持，
        // 是完全另一回事——那时该如实报"不支持"，而不是换一个"支持的"语言硬翻。
        //
        // 这条用长文本把边界钉住：Configuración 会被高置信度识别为 es（0.98），
        // 所以协调器里那个 `detection == nil` 的判断根本不会走到兜底；
        // 而兜底函数本身只看脚本，对同一段文本会给出 en——两者必须靠调用点区分开，
        // 不能靠兜底函数自己"聪明"。
        let resolved = LanguageScriptFallback.sourceLanguageCode(for: "Configuración")
        #expect(resolved == "en")

        let detected = LanguageDetectionService.shared
            .detectLanguage(in: "Configuración")?
            .languageCode
        #expect(detected == "es")
        // 两者不同，正是为什么"什么时候调用兜底"必须由调用点严格把关。
        #expect(detected != resolved)
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
