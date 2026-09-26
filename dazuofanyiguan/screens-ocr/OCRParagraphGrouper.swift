import CoreGraphics
import Foundation

/// 把 Vision 给出的一行行文字按版面拼回段落。
///
/// Vision 只给「视觉行」：一句话折成三行就是三条结果。逐行送去翻译，译文会断成半句话
/// （实测 "in half" 单独成行被翻成「在半小时内」）。旧实现只看「行尾是否贴近选区右边、
/// 行首是否贴近选区左边」，框宽一点就不拼；双栏文章还会把右栏第一行和左栏第二行拼成一句。
///
/// 这里只看行与行之间的几何关系，和选区大小无关：同一栏、字号相近、行距是正文行距、
/// 上一行写满了、上一行没有以句末标点结束、下一行不是新的列表项，才拼成一段。
/// 宁可少拼：拼错会把两条不相干的界面文字翻成一句，少拼只是退回到逐行翻译。
///
/// 尺子用「宽度 ÷ 字数」估出来的字号，不用行框高度：实测上方有大标题时，Vision 会把段落里
/// 某一行的框上下各撑出 9～10pt，框高是别的行的两倍多；宽度则很稳定。
/// 行距按框的中心量——撑大的框顶边、底边都会跑，中心偏差在 3pt 以内。
enum OCRParagraphGrouper {
    private struct Item {
        let line: VisionOCRService.OCRLine
        /// 图片像素坐标，左上原点、y 向下。
        let rect: CGRect
        /// 估算字号（像素）。
        let em: CGFloat
        let characterCount: Int
    }

    /// 按字符宽度估算的字号：行宽 ÷ 这行字的总宽度（以字号为单位）。
    /// 系数按系统字体实测：小写字母约 0.5 个字号宽，大写和数字约 0.62，空格约 0.28，
    /// 汉字、假名是 1，谚文是 0.86。
    static func estimatedEm(width: CGFloat, text: String) -> CGFloat {
        width / emCount(of: text)
    }

    private static func emCount(of text: String) -> CGFloat {
        var count: CGFloat = 0
        for character in text {
            if character == " " {
                count += 0.28
            } else if isHangul(character) {
                count += 0.86
            } else if isFullWidth(character) {
                count += 1
            } else if character.isUppercase || character.isNumber {
                count += 0.62
            } else if character.isLetter {
                count += 0.5
            } else {
                count += 0.3
            }
        }
        return max(count, 0.5)
    }

    static func group(_ lines: [VisionOCRService.OCRLine], imageSize: CGSize) -> [VisionOCRService.OCRBlock] {
        guard !lines.isEmpty else { return [] }
        let width = max(imageSize.width, 1)
        let height = max(imageSize.height, 1)

        let items = readingOrder(lines.map { line in
            let box = line.boundingBox
            let rect = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            return Item(
                line: line,
                rect: rect,
                em: estimatedEm(width: rect.width, text: line.text),
                characterCount: line.text.count
            )
        })

        var paragraphs: [[Int]] = []
        var paragraphOfItem = Array(repeating: -1, count: items.count)
        for index in items.indices {
            if let above = nearestLineAbove(index, in: items) {
                let paragraph = paragraphOfItem[above]
                if paragraphs[paragraph].last == above,
                   canContinue(paragraphs[paragraph].map { items[$0] }, with: items[index], among: items) {
                    paragraphs[paragraph].append(index)
                    paragraphOfItem[index] = paragraph
                    continue
                }
            }
            paragraphOfItem[index] = paragraphs.count
            paragraphs.append([index])
        }

        return paragraphs.map { indices in
            let members = indices.map { items[$0].line }
            let text = members.dropFirst().reduce(members[0].text) { joinLines($0, $1.text) }
            return VisionOCRService.OCRBlock(text: text, lines: members)
        }
    }

    /// 两行拼接时中间要不要空格。
    static func joinLines(_ first: String, _ second: String) -> String {
        guard let last = first.last, let head = second.first else { return first + second }
        if isUnspacedScript(last) || isUnspacedScript(head) {
            return first + second
        }
        // 行尾连字符：保留、不加空格。分不清是断词（impor-tant）还是复合词（self-driving），
        // 保留时两种情况都只是多一个「-」；去掉则会把复合词粘成一个错词。
        if last == "-" || last == "\u{2010}", first.dropLast().last?.isLetter == true {
            return first + second
        }
        return first + " " + second
    }

    // MARK: - 阅读顺序

    /// 先分行（中心相差不到半个字号算同一行）从上到下，同一行内从左到右。
    /// 旧实现用「中心点相差不到图片高度的 2%」判同一行：框得很高时，
    /// 相距一行的两行文字会被当成同一行，上下顺序颠倒。
    private static func readingOrder(_ items: [Item]) -> [Item] {
        let sorted = items.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[Item]] = []
        for item in sorted {
            if let anchor = rows.last?.first,
               abs(anchor.rect.midY - item.rect.midY) <= 0.45 * min(anchor.em, item.em) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.flatMap { row in row.sorted { $0.rect.minX < $1.rect.minX } }
    }

    // MARK: - 拼接判定

    /// 正上方、同一栏里离得最近的那一行。只在阅读顺序更靠前（已经分好段）的行里找。
    private static func nearestLineAbove(_ index: Int, in items: [Item]) -> Int? {
        let item = items[index]
        let rect = item.rect
        var best: Int?
        for candidate in items.indices where candidate < index {
            let other = items[candidate].rect
            guard other.midY + 0.6 * min(item.em, items[candidate].em) <= rect.midY else { continue }
            guard horizontalOverlap(other, rect) >= 0.3 * min(other.width, rect.width) else { continue }
            if let best, items[best].rect.midY >= other.midY { continue }
            best = candidate
        }
        return best
    }

    private static func canContinue(_ paragraph: [Item], with next: Item, among items: [Item]) -> Bool {
        guard let previous = paragraph.last else { return false }
        let p = previous.rect
        let n = next.rect
        let em = (previous.em + next.em) / 2
        guard em > 0 else { return false }

        // 1. 字号相近。字数太少时估算不准，放宽一些。
        let sizeTolerance: CGFloat = min(previous.characterCount, next.characterCount) < 8 ? 1.45 : 1.25
        guard max(previous.em, next.em) / min(previous.em, next.em) <= sizeTolerance else { return false }

        // 2. 行距像正文行距；界面列表的行距通常在两个字号以上。
        //    顶边、中心、底边三种量法任一落在范围内就算：框常常只往一头撑（实测顶边多出 9pt），
        //    另一头量出来的仍是真实行距。也不要求和段内已有行距一致——框一抖就会误拆，
        //    段与段之间主要靠句末标点分开。
        let pitches = [n.minY - p.minY, n.midY - p.midY, n.maxY - p.maxY]
        guard pitches.contains(where: { $0 >= 0.85 * em && $0 <= 1.95 * em }) else { return false }

        // 3. 对齐：左对齐、首行缩进、列表项的悬挂缩进、居中。
        let previousText = previous.line.text.trimmingCharacters(in: .whitespaces)
        let nextText = next.line.text.trimmingCharacters(in: .whitespaces)
        let leftAligned = abs(p.minX - n.minX) <= 1.2 * em
        let firstLineIndent = paragraph.count == 1
            && p.minX > n.minX && p.minX - n.minX <= 4 * em
        let hangingIndent = paragraph.count == 1 && startsWithListMarker(previousText)
            && n.minX > p.minX && n.minX - p.minX <= 3.5 * em
        let centered = abs(p.midX - n.midX) <= 1.2 * em
        guard leftAligned || firstLineIndent || hangingIndent || centered else { return false }

        // 4. 上一行写满了：本身够长，右端贴近这一栏的右边界。
        guard p.width >= 6 * em else { return false }
        let columnLeft = min(paragraph.map(\.rect.minX).min() ?? p.minX, n.minX)
        let columnRight = columnRightEdge(previous: previous, next: next, paragraph: paragraph, items: items)
        let tolerance = max(2.5 * em, 0.18 * (columnRight - columnLeft))
        if centered && !leftAligned && !firstLineIndent && !hangingIndent {
            // 居中的段落左右都不齐，改看宽度。
            guard p.width >= columnRight - columnLeft - 2 * tolerance else { return false }
        } else {
            guard p.maxX >= columnRight - tolerance else { return false }
        }

        // 5. 文字本身的信号。
        if endsSentence(previousText) { return false }
        if startsWithListMarker(nextText) { return false }
        // 大写开头多半是新的一条（界面列表几乎都是这样）。只在决定「要不要开始拼」时看：
        // 已经连成两行以上的段落，后面的行大写开头照样接上，免得德语名词把段落拆碎。
        if paragraph.count == 1, let first = nextText.first, first.isUppercase { return false }

        return true
    }

    /// 这一栏的右边界：上一行附近、与它左对齐且字号相近的行里最靠右的那个。
    /// 只看这一段自己会低估栏宽：两行的段落里，较长那行永远「写满」。
    private static func columnRightEdge(previous: Item, next: Item, paragraph: [Item], items: [Item]) -> CGFloat {
        let p = previous.rect
        let em = previous.em
        var right = max(p.maxX, next.rect.maxX)
        for item in paragraph {
            right = max(right, item.rect.maxX)
        }
        for item in items {
            let r = item.rect
            guard abs(r.minX - p.minX) <= 1.2 * em,
                  max(item.em, em) / min(item.em, em) <= 1.25,
                  abs(r.midY - p.midY) <= 12 * em else { continue }
            right = max(right, r.maxX)
        }
        return right
    }

    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "】", "》", "]"]
        var trimmed = Substring(text)
        while let last = trimmed.last, closers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return ".!?。！？…:：;；".contains(last)
    }

    private static let listMarkerPattern = try? NSRegularExpression(
        pattern: "^(?:[•·◦▪▫‣●○■□▶►✓✔☐☑*+\\-–—](?:\\s|$)|\\(?\\d{1,3}[.)．](?:\\s|$)|\\d{1,3}、|[a-zA-Z][.)]\\s|[一二三四五六七八九十]{1,3}、)"
    )

    private static func startsWithListMarker(_ text: String) -> Bool {
        guard let listMarkerPattern else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return listMarkerPattern.firstMatch(in: text, options: [.anchored], range: range) != nil
    }

    /// 词与词之间不用空格的书写系统：汉字、假名、泰文，以及 CJK 标点和全角字符。
    /// 韩文按词加空格，不在其中。
    private static func isUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0E7F,
                 0x3000...0x303F,
                 0x3040...0x30FF,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }

    /// 占满一个字宽的字符：汉字、假名、CJK 标点和全角字符。
    private static func isFullWidth(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,
                 0x3040...0x30FF,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0xFF00...0xFF60,
                 0xFFE0...0xFFE6:
                return true
            default:
                return false
            }
        }
    }

    private static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

}
