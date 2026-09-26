import Foundation
import Testing
@testable import 大佐翻译官v1

@Suite("控制台筛选与复制")
struct LogConsoleFilterTests {
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// 按时间正序追加，和 `LogStore.entries` 的顺序一致。
    private let entries: [LogStore.Entry] = [
        .init(date: base, level: "INFO", message: "开始翻译（引擎：Google）"),
        .init(date: base.addingTimeInterval(1), level: "WARN", message: "翻译遇到限流：429，2秒后重试"),
        .init(date: base.addingTimeInterval(2), level: "ERROR", message: "读取 Keychain 失败：拒绝访问"),
        .init(date: base.addingTimeInterval(3), level: "INFO", message: "翻译完成（812ms）"),
    ]

    @Test("不筛选时全部显示，最新的在最上面")
    func unfilteredNewestFirst() {
        let visible = LogConsoleFilter.visibleEntries(entries, level: nil, query: "")
        #expect(visible.map(\.message) == entries.reversed().map(\.message))
    }

    @Test("按级别筛选")
    func filterByLevel() {
        let warn = LogConsoleFilter.visibleEntries(entries, level: .warn, query: "")
        #expect(warn.map(\.level) == ["WARN"])

        let info = LogConsoleFilter.visibleEntries(entries, level: .info, query: "")
        #expect(info.map(\.message) == ["翻译完成（812ms）", "开始翻译（引擎：Google）"])
    }

    @Test("关键字不分大小写，首尾空白忽略，可以和级别叠加")
    func filterByQuery() {
        #expect(LogConsoleFilter.visibleEntries(entries, level: nil, query: "  keychain ").map(\.level) == ["ERROR"])
        #expect(LogConsoleFilter.visibleEntries(entries, level: nil, query: "翻译").count == 3)
        #expect(LogConsoleFilter.visibleEntries(entries, level: .info, query: "翻译").count == 2)
        #expect(LogConsoleFilter.visibleEntries(entries, level: .error, query: "翻译").isEmpty)
    }

    @Test("关键字只有空白时等于不搜索")
    func whitespaceQueryIsNoQuery() {
        #expect(LogConsoleFilter.visibleEntries(entries, level: nil, query: " \n ").count == entries.count)
    }

    @Test("按级别计数；认不出的级别不算进任何一类")
    func countByLevel() {
        let withUnknown = entries + [.init(date: Self.base, level: "DEBUG", message: "x")]
        #expect(LogConsoleFilter.count(withUnknown, level: .info) == 2)
        #expect(LogConsoleFilter.count(withUnknown, level: .warn) == 1)
        #expect(LogConsoleFilter.count(withUnknown, level: .error) == 1)
        #expect(LogConsoleFilter.visibleEntries(withUnknown, level: nil, query: "").count == 5)
    }

    @Test("级别字符串不分大小写")
    func levelParsing() {
        #expect(LogConsoleLevel(level: "warn") == .warn)
        #expect(LogConsoleLevel(level: "ERROR") == .error)
        #expect(LogConsoleLevel(level: "DEBUG") == nil)
    }

    @Test("复制出的文本按时间正序，一行一条")
    func clipboardIsChronological() {
        let visible = LogConsoleFilter.visibleEntries(entries, level: nil, query: "翻译")
        let lines = LogConsoleFilter.clipboardText(visible).components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix("[INFO] 开始翻译（引擎：Google）"))
        #expect(lines[1].hasSuffix("[WARN] 翻译遇到限流：429，2秒后重试"))
        #expect(lines[2].hasSuffix("[INFO] 翻译完成（812ms）"))
        #expect(lines[0].hasPrefix(LogConsoleFilter.timeText(Self.base) + " "))
    }

    @Test("时间固定为 24 小时制 HH:mm:ss")
    func timeFormat() {
        let text = LogConsoleFilter.timeText(Self.base)
        #expect(text.count == 8)
        #expect(text.filter { $0 == ":" }.count == 2)
    }
}
