import Foundation

/// 目标语言列表的规整与同源过滤（PRD §10）。
///
/// 全部是纯函数：不读设置、不碰 UI，直接单测。
enum InputAssistLanguagePolicy {
    static let maximumTargetCount = 6
    /// 超过这个数量仍然允许，只是在设置页轻提示（PRD §10.1）。
    static let recommendedTargetCount = 3
    static let defaultTargetCodes = ["en"]

    /// 选中文本为明确的汉字文本时，不盲信长文通用语言识别。
    ///
    /// 不能再把整段长文丢给通用语言识别后盲信结果：数字、型号、多个标点和
    /// 中英混排会让 NLLanguageRecognizer 返回非中文或 nil，Apple Translation 随后检查错误的
    /// 语言对，已安装的中文包也会被误报成“需要下载”。
    static func selectionSourceLanguageCode(
        for text: String,
        detectedLanguageCode: String?
    ) -> String? {
        let scripts = TextScriptPresence(in: text)
        guard scripts.containsHan else {
            return detectedLanguageCode
        }

        if detectedLanguageCode == "zh-CN" || detectedLanguageCode == "zh-TW" {
            return detectedLanguageCode
        }

        // 明确包含日文假名时保留日文识别；纯汉字 / 中英混排按本功能的中文输入语义处理。
        if scripts.containsKana, detectedLanguageCode == "ja" {
            return detectedLanguageCode
        }
        // 谚文同理：韩文里混着汉字（`한자漢字`）很常见，
        // 不能因为出现汉字就把已经正确识别出来的韩文压成中文。
        // 这和 `LanguageScriptFallback` 里「假名 / 谚文排在汉字前面」是同一条规则，
        // 两处必须一致。
        if scripts.containsHangul, detectedLanguageCode == "ko" {
            return detectedLanguageCode
        }
        return "zh-CN"
    }

    /// 去重并截断到 6 个。
    ///
    /// 顺序严格按用户配置保留——PRD §10.3 明确禁止按使用频率重排，
    /// 所以这里只做「删」不做「移」。
    static func sanitizeTargets(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for code in codes {
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let normalized = normalize(trimmed)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(trimmed)
            if result.count == maximumTargetCount { break }
        }
        return result
    }

    /// 隐藏与源语言相同的目标（PRD §10.4）。
    ///
    /// 源语言未知时（auto、或短文本检测不出来）一个都不隐藏：
    /// 宁可多显示一行候选，也不要凭猜测吞掉用户明确配置过的语言。
    static func visibleTargets(
        _ targets: [String],
        sourceLanguageCode: String?
    ) -> [String] {
        guard let sourceLanguageCode,
              !sourceLanguageCode.isEmpty,
              sourceLanguageCode != LanguagePreset.auto.code
        else {
            return targets
        }
        return targets.filter { !isSameLanguage($0, sourceLanguageCode) }
    }

    /// 语言码是否指向同一种语言。
    ///
    /// 主语言不同 → 不同。主语言相同时，只有「双方都带了地区/字体子标签且不一致」
    /// 才算不同，因此 zh-CN 与 zh-TW 是两种语言，而 en 与 en-US 是同一种。
    static func isSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let left = subtags(of: lhs)
        let right = subtags(of: rhs)
        guard left.base == right.base else { return false }
        guard let leftVariant = left.variant, let rightVariant = right.variant else {
            return true
        }
        return leftVariant == rightVariant
    }

    private static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }



    private static func subtags(of code: String) -> (base: String, variant: String?) {
        let parts = normalize(code).split(separator: "-", omittingEmptySubsequences: true)
        guard let base = parts.first else { return ("", nil) }
        return (String(base), parts.count > 1 ? String(parts[1]) : nil)
    }
}
