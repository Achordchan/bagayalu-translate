import CoreGraphics
import Foundation

/// 候选浮层的尺寸计算（PRD §12 / §13）。纯函数，可直接单测。
enum CandidatePanelLayout {
    static let width: CGFloat = 420
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 1
    static let rowVerticalPadding: CGFloat = 5
    static let lineHeight: CGFloat = 18
    static let debugLineHeight: CGFloat = 14
    static let copyNoticeHeight: CGFloat = 25
    /// 语言码那一列的宽度，纵向对齐用。
    static let languageColumnWidth: CGFloat = 34

    /// 普通候选最多 2 行（PRD §13.1）。
    static let normalRowMaximumLines = 2
    /// 当前高亮候选可以展开到 4 行（PRD §13.2）。
    static let selectedRowMaximumLines = 4

    /// 一行大约能放多少个字符。中文比拉丁字母宽，取保守值。
    static let estimatedCharactersPerLine = 42

    /// 中文译成拉丁语系时字符数会明显变多：
    /// 「我们可以提供16吨船吊」11 个字 → "We can provide a 16-ton marine crane." 37 个字符。
    /// 预留高度时必须把这个膨胀算进去，否则一出结果浮层就得长高。
    static let cjkExpansionFactor = 2.6
    static let latinExpansionFactor = 1.2

    /// **在浮层出现之前**就把每行要占多少行文字定下来。
    ///
    /// PRD §12.2 要求「不得随着每个翻译返回而不断增加 Panel 高度」。
    /// 所以行高不能依赖译文——译文是陆续到的，那样每回来一个语言浮层就跳一次。
    /// 改成从**原文**估算：原文在弹出的那一刻就已经知道了。
    static func reservedLineCount(forSourceText sourceText: String) -> Int {
        let characters = Double(sourceText.count)
        guard characters > 0 else { return 1 }
        let factor = containsCJK(sourceText) ? cjkExpansionFactor : latinExpansionFactor
        let estimated = (characters * factor) / Double(estimatedCharactersPerLine)
        return max(1, min(selectedRowMaximumLines, Int(estimated.rounded(.up))))
    }

    /// 某一行实际渲染几行文字。只取决于预留值和是不是高亮行，**与译文无关**。
    static func lineCount(reservedLineCount: Int, isSelected: Bool) -> Int {
        let maximum = isSelected ? selectedRowMaximumLines : normalRowMaximumLines
        return max(1, min(maximum, reservedLineCount))
    }

    static func rowHeight(
        reservedLineCount: Int,
        isSelected: Bool,
        showsDebugInfo: Bool
    ) -> CGFloat {
        let textHeight = CGFloat(
            lineCount(reservedLineCount: reservedLineCount, isSelected: isSelected)
        ) * lineHeight
        let debugHeight = showsDebugInfo ? debugLineHeight : 0
        return textHeight + debugHeight + rowVerticalPadding * 2
    }

    /// 浮层整体尺寸。
    ///
    /// 只依赖「几行候选」「哪一行高亮」「预留几行文字」「要不要显示调试信息」——
    /// 全部在浮层出现时就已确定，或者由用户操作改变。
    /// 翻译陆续返回**不会**改变任何一项，所以浮层不会跳。
    static func panelSize(
        rowCount: Int,
        selectedIndex: Int,
        reservedLineCount: Int,
        showsDebugInfo: Bool,
        showsCopyNotice: Bool = false
    ) -> CGSize {
        guard rowCount > 0 else {
            return CGSize(width: width, height: lineHeight + verticalPadding * 2)
        }
        let rowsHeight = (0..<rowCount).reduce(CGFloat.zero) { total, index in
            total + rowHeight(
                reservedLineCount: reservedLineCount,
                isSelected: index == selectedIndex,
                showsDebugInfo: showsDebugInfo
            )
        }
        let spacing = rowSpacing * CGFloat(max(0, rowCount - 1))
        let noticeHeight = showsCopyNotice ? copyNoticeHeight : 0
        return CGSize(
            width: width,
            height: rowsHeight + spacing + verticalPadding * 2 + noticeHeight
        )
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // 假名
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xAC00...0xD7AF,   // 谚文
                 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
