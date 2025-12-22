import Foundation

struct Language: Identifiable, Hashable {
    let id: String
    let code: String
    let name: String

    init(code: String, name: String) {
        self.id = code
        self.code = code
        self.name = name
    }
}

enum LanguagePreset {
    static let auto = Language(code: "auto", name: "自动检测")

    static let screenshotSource: [Language] = [
        .init(code: "en", name: "英语"),
        .init(code: "ru", name: "俄语"),
        .init(code: "es", name: "西班牙语")
    ]

    static let common: [Language] = [
        .init(code: "auto", name: "自动检测"),
        .init(code: "zh-CN", name: "中文（简体）"),
        .init(code: "zh-TW", name: "中文（繁体）"),
        .init(code: "en", name: "英语"),
        .init(code: "ja", name: "日语"),
        .init(code: "ko", name: "韩语"),
        .init(code: "it", name: "意大利语"),
        .init(code: "fr", name: "法语"),
        .init(code: "de", name: "德语"),
        .init(code: "es", name: "西班牙语"),
        .init(code: "pt", name: "葡萄牙语"),
        .init(code: "nl", name: "荷兰语"),
        .init(code: "sv", name: "瑞典语"),
        .init(code: "da", name: "丹麦语"),
        .init(code: "no", name: "挪威语"),
        .init(code: "fi", name: "芬兰语"),
        .init(code: "pl", name: "波兰语"),
        .init(code: "cs", name: "捷克语"),
        .init(code: "hu", name: "匈牙利语"),
        .init(code: "ro", name: "罗马尼亚语"),
        .init(code: "bg", name: "保加利亚语"),
        .init(code: "el", name: "希腊语"),
        .init(code: "uk", name: "乌克兰语"),
        .init(code: "ru", name: "俄语"),
        .init(code: "tr", name: "土耳其语"),
        .init(code: "ar", name: "阿拉伯语"),
        .init(code: "he", name: "希伯来语"),
        .init(code: "fa", name: "波斯语"),
        .init(code: "hi", name: "印地语"),
        .init(code: "bn", name: "孟加拉语"),
        .init(code: "ta", name: "泰米尔语"),
        .init(code: "th", name: "泰语"),
        .init(code: "vi", name: "越南语"),
        .init(code: "id", name: "印尼语"),
        .init(code: "ms", name: "马来语"),
        .init(code: "fil", name: "菲律宾语"),
        .init(code: "ur", name: "乌尔都语"),
        .init(code: "sw", name: "斯瓦希里语")
    ]

    static func displayName(for code: String) -> String {
        common.first(where: { $0.code == code })?.name ?? code
    }
}
