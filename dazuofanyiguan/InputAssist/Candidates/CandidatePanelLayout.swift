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
    /// 语言码那一列的宽度，纵向对齐用。
    static let languageColumnWidth: CGFloat = 34

    /// 普通候选最多 2 行（PRD §13.1）。
    static let normalRowMaximumLines = 2
    /// 当前高亮候选可以展开到 4 行（PRD §13.2）。
    static let selectedRowMaximumLines = 4

    /// 一行大约能放多少个字符。中文比拉丁字母宽，取保守值。
    static let estimatedCharactersPerLine = 42

    static func lineCount(for row: CandidateRow, isSelected: Bool) -> Int {
        let maximum = isSelected ? selectedRowMaximumLines : normalRowMaximumLines
        switch row.state {
        case .loading, .languagePackRequired:
            return 1
        case .failed:
            return 1
        case .translated(let text, _, _):
            let wrapped = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(into: 0) { total, paragraph in
                    total += max(1, Int(ceil(Double(paragraph.count) / Double(estimatedCharactersPerLine))))
                }
            return min(maximum, max(1, wrapped))
        }
    }

    static func rowHeight(for row: CandidateRow, isSelected: Bool, showsDebugInfo: Bool) -> CGFloat {
        let textHeight = CGFloat(lineCount(for: row, isSelected: isSelected)) * lineHeight
        let debugHeight = showsDebugInfo ? debugLineHeight : 0
        return textHeight + debugHeight + rowVerticalPadding * 2
    }

    /// 浮层整体尺寸。
    ///
    /// 行数在第一次出现时就固定下来（PRD §12.2：不能随着每个语言返回而一条条长出来），
    /// 之后只有高亮位置变化才会改变高度。
    static func panelSize(
        rows: [CandidateRow],
        selectedIndex: Int,
        showsDebugInfo: Bool
    ) -> CGSize {
        guard !rows.isEmpty else {
            return CGSize(width: width, height: lineHeight + verticalPadding * 2)
        }
        let rowsHeight = rows.indices.reduce(CGFloat.zero) { total, index in
            total + rowHeight(
                for: rows[index],
                isSelected: index == selectedIndex,
                showsDebugInfo: showsDebugInfo
            )
        }
        let spacing = rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(
            width: width,
            height: rowsHeight + spacing + verticalPadding * 2
        )
    }
}
