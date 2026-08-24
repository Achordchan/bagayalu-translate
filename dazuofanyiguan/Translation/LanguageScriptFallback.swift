import Foundation

/// 通用语言识别放弃时，用书写系统本身能确定的部分兜底。
///
/// 起因：短语几乎必然让 `NLLanguageRecognizer` 弃权，而弃权之后我们会把
/// `sourceLanguage: nil` 交给 Apple Translation——它自己在短语上同样认不出，
/// 于是弹出「无法自动检测语言。请选择要翻译的语言。」那个选择器，
/// 在 Mini 气泡的场景里那是个死胡同。
///
/// 实测（`NLLanguageRecognizer.languageHypotheses`，2026-08-25）：
///
/// | 文本 | 字母数 | 我们的判定 | 识别器前三 |
/// |---|---|---|---|
/// | `TestHost` | 8 | nil（置信度） | cs:0.21 en:0.13 nl:0.09 |
/// | `Settings` | 8 | nil（置信度） | en:0.33 sv:0.16 is:0.11 |
/// | `hello world` | 10 | nil（置信度） | en:0.31 id:0.10 hu:0.08 |
/// | `设置` | 2 | nil（字数不足） | **zh-Hans:1.00** |
/// | `你好` | 2 | nil（字数不足） | **zh-Hant:0.80** zh-Hans:0.20 |
///
/// 前三行说明识别器在短 Latin 词上基本没有价值——`TestHost` 它排第一的是捷克语，
/// 所以 0.60 的阈值挡掉它是对的，不该为了这种情况去调低阈值。
/// 后两行说明另一件事：**脚本本身已经把答案写在脸上了，我们却因为字数门槛把它扔了。**
///
/// 所以这里不碰识别器的判定，只在它弃权之后补一层脚本兜底。
enum LanguageScriptFallback {
    /// 识别器弃权时的最佳猜测。返回 nil 表示连脚本都给不出信息（纯数字 / 符号）。
    ///
    /// 顺序有讲究：假名和谚文要排在汉字前面——日文正文里混着汉字，
    /// 韩文里也可能出现汉字，先判汉字会把它们都认成中文。
    static func sourceLanguageCode(
        for text: String,
        preferredChineseVariant: String = "zh-CN",
        latinDefault: String = "en"
    ) -> String? {
        let scripts = TextScriptPresence(in: text)

        if scripts.containsKana { return "ja" }
        if scripts.containsHangul { return "ko" }
        if scripts.containsHan || scripts.containsBopomofo {
            return normalizedChineseVariant(preferredChineseVariant)
        }
        if scripts.containsCyrillic { return "ru" }
        if scripts.containsLatin {
            // Latin 覆盖了几十种语言，八个字母分不出 en / es / nl。
            // 但"猜一个"仍然远好过把 nil 交给 Apple 然后弹选择器：
            // 猜错顶多译得不准，交 nil 是直接走不下去。
            return latinDefault
        }
        return nil
    }

    private static func normalizedChineseVariant(_ code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard normalized == "zh" || normalized.hasPrefix("zh-") else { return "zh-CN" }
        return normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hant")
            ? "zh-TW"
            : "zh-CN"
    }
}
