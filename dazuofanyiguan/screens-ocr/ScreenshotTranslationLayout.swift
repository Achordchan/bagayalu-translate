import AppKit

/// 译文回贴的排版：每段译文放在哪、多大字号、怎么对齐、要抹掉哪块原文。
/// 纯计算，坐标是选区内的 pt、左上原点；量字宽的函数从外面传进来，方便单测。
///
/// 规则按「尽量像原图」排：
/// - 字号用原文的字号（渲染器按墨迹宽度反推出来，再把相近的归成一档），同样大的原文译出来也一样大。
/// - 译文只往空白处延伸，能延伸到哪由渲染器看像素定（`Limits`：碰到别的文字、图标、分隔线、色块边缘为止）。
/// - 单行：尽量一行放下，放不下先往空白处延伸、再小幅缩小（最多到 82%），然后折行往下占空白，
///   还不行就继续缩小（最多到 70%），最后截断。居中的（按钮、表格里居中的字）以原来的中心为准左右对称地延伸。
/// - 多行段落：在原段落的宽度里重排，行距跟原文，第一行和原文第一行对齐；放不下先往下占空白，
///   再缩小（最多到 62%），最后截断。完整译文在「对照」里看。
/// - 只抹原文所在的地方：译文延伸出去的地方本来就是空白，不动它，按钮、卡片的边也就不会被抹掉。
enum ScreenshotTranslationLayout {
    struct Block {
        let id: UUID
        let text: String
        /// 原文每一行墨迹的范围。
        let lines: [CGRect]
        /// 原文字号（pt）。
        let fontSize: CGFloat
        let weight: NSFont.Weight
        let alignment: NSTextAlignment
        /// 译文最多能占到哪。
        let limits: Limits

        var bounds: CGRect {
            guard let first = lines.first else { return .zero }
            return lines.dropFirst().reduce(first) { $0.union($1) }
        }

        /// 相邻两行中心距离的中位数；单行为 nil。
        var pitch: CGFloat? {
            guard lines.count > 1 else { return nil }
            let pitches = zip(lines.dropFirst(), lines).map { $0.midY - $1.midY }.sorted()
            return pitches[pitches.count / 2]
        }
    }

    /// 译文能占到的左右、下边界（pt）。
    struct Limits: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var maxY: CGFloat
    }

    struct Placement {
        let id: UUID
        let text: String
        let frame: CGRect
        let fontSize: CGFloat
        /// 多行时固定的行高；单行为 nil（用字体自然行高）。
        let lineHeight: CGFloat?
        let alignment: NSTextAlignment
        let weight: NSFont.Weight
        /// 要抹掉的范围：原文各行（各自外扩一点，盖住抗锯齿的边）。
        let eraseRects: [CGRect]
    }

    /// 量一段文字排出来的大小：`width` 为 nil 时不折行。
    typealias Measure = (_ text: String, _ fontSize: CGFloat, _ weight: NSFont.Weight, _ width: CGFloat?, _ lineHeight: CGFloat?) -> CGSize

    /// 相近的字号（相差 12% 以内）归成一档、取中位数：Vision 的行框和字符宽度都有抖动，
    /// 不归档的话同一列表里的几行会译成大小不一的字。
    static func harmonizedFontSizes(_ sizes: [CGFloat]) -> [CGFloat] {
        let order = sizes.indices.sorted { sizes[$0] < sizes[$1] }
        var result = sizes
        var group: [Int] = []
        func flush() {
            guard !group.isEmpty else { return }
            let values = group.map { sizes[$0] }.sorted()
            let median = values[values.count / 2]
            for index in group { result[index] = median }
            group = []
        }
        for index in order {
            if let first = group.first, sizes[index] > sizes[first] * 1.12 {
                flush()
            }
            group.append(index)
        }
        flush()
        return result
    }

    static func plan(_ blocks: [Block], canvas: CGSize, measure: Measure = systemMeasure) -> [Placement] {
        blocks.compactMap { block in
            guard !block.lines.isEmpty, block.fontSize > 0 else { return nil }
            return place(block, canvas: canvas, measure: measure)
        }
    }

    /// 缩小时每次减 2%，找能放下的最大字号。
    private static func sizes(from size: CGFloat, downTo floor: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        var value = size
        while value >= floor - 0.001 {
            result.append(value)
            value -= size * 0.02
        }
        if result.last.map({ $0 > floor + 0.001 }) ?? true {
            result.append(floor)
        }
        return result
    }

    private static func place(_ block: Block, canvas: CGSize, measure: Measure) -> Placement {
        let bounds = block.bounds
        let size = block.fontSize
        let limits = Limits(
            minX: max(0, min(block.limits.minX, bounds.minX)),
            maxX: min(canvas.width, max(block.limits.maxX, bounds.maxX)),
            maxY: min(canvas.height, max(block.limits.maxY, bounds.maxY))
        )
        let erase = block.lines.map { line in
            line.insetBy(dx: -0.12 * size, dy: -max(0.5, 0.08 * size))
                .intersection(CGRect(origin: .zero, size: canvas))
        }
        func placement(_ frame: CGRect, _ fontSize: CGFloat, lineHeight: CGFloat?, alignment: NSTextAlignment) -> Placement {
            Placement(
                id: block.id,
                text: block.text,
                frame: frame,
                fontSize: fontSize,
                lineHeight: lineHeight,
                alignment: alignment,
                weight: block.weight,
                eraseRects: erase
            )
        }
        let wrapFloor = max(8, size * 0.7)
        // 段落宁可再小一点也别截断：截掉的是整句话，单行截掉的多半只是个尾巴。
        let paragraphFloor = max(8, size * 0.62)

        if block.lines.count == 1 {
            let line = block.lines[0]
            // 可用宽度：左对齐往右延伸；居中以原中心左右对称；右对齐往左延伸。
            let span: (minX: CGFloat, maxX: CGFloat)
            switch block.alignment {
            case .center:
                let half = max(line.width / 2, min(line.midX - limits.minX, limits.maxX - line.midX))
                span = (line.midX - half, line.midX + half)
            case .right:
                span = (limits.minX, line.maxX)
            default:
                span = (line.minX, limits.maxX)
            }
            let maxWidth = max(line.width, span.maxX - span.minX)

            func singleLine(_ fontSize: CGFloat, width: CGFloat) -> CGRect {
                let height = measure("Ag字", fontSize, block.weight, nil, nil).height
                let x: CGFloat
                switch block.alignment {
                case .center: x = line.midX - width / 2
                case .right: x = line.maxX - width
                default: x = line.minX
                }
                return CGRect(x: x, y: line.midY - height / 2, width: width, height: height)
            }

            // 1. 一行放下，最多缩到 82%。
            for fontSize in sizes(from: size, downTo: max(8, size * 0.82)) {
                let natural = measure(block.text, fontSize, block.weight, nil, nil)
                if natural.width <= maxWidth {
                    return placement(singleLine(fontSize, width: natural.width + 1), fontSize, lineHeight: nil, alignment: block.alignment)
                }
            }
            // 2. 折行往下占空白，最多缩到 70%。
            for fontSize in sizes(from: size, downTo: wrapFloor) {
                let first = singleLine(fontSize, width: maxWidth)
                let height = measure(block.text, fontSize, block.weight, maxWidth, nil).height
                if first.minY + height <= limits.maxY {
                    let frame = CGRect(x: first.minX, y: first.minY, width: maxWidth, height: height)
                    return placement(frame, fontSize, lineHeight: nil, alignment: block.alignment)
                }
            }
            // 3. 一行、缩到 70%，放不下截断。
            for fontSize in sizes(from: max(8, size * 0.82), downTo: wrapFloor) {
                let natural = measure(block.text, fontSize, block.weight, nil, nil)
                if natural.width <= maxWidth || fontSize <= wrapFloor + 0.001 {
                    let width = min(natural.width + 1, maxWidth)
                    return placement(singleLine(fontSize, width: width), fontSize, lineHeight: nil, alignment: block.alignment)
                }
            }
            return placement(singleLine(wrapFloor, width: maxWidth), wrapFloor, lineHeight: nil, alignment: block.alignment)
        }

        // 多行段落：在原宽度里重排，行距跟原文。
        let width = bounds.width
        let pitch = block.pitch ?? size * 1.4
        func lineHeight(for fontSize: CGFloat) -> CGFloat {
            min(max(pitch * fontSize / size, 1.12 * fontSize), 1.9 * fontSize)
        }
        for fontSize in sizes(from: size, downTo: paragraphFloor) {
            let height = measure(block.text, fontSize, block.weight, width, lineHeight(for: fontSize)).height
            let top = block.lines[0].midY - lineHeight(for: fontSize) / 2
            if top + height <= limits.maxY {
                return placement(
                    CGRect(x: bounds.minX, y: top, width: width, height: height),
                    fontSize,
                    lineHeight: lineHeight(for: fontSize),
                    alignment: block.alignment
                )
            }
        }
        let top = block.lines[0].midY - lineHeight(for: paragraphFloor) / 2
        return placement(
            CGRect(x: bounds.minX, y: top, width: width, height: max(lineHeight(for: paragraphFloor), limits.maxY - top)),
            paragraphFloor,
            lineHeight: lineHeight(for: paragraphFloor),
            alignment: block.alignment
        )
    }

    /// 排版和绘制共用同一份文字属性，量出来的大小才和画出来的一致。
    static func attributedString(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment,
        lineHeight: CGFloat?
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            // 固定行高时多出来的空间默认全堆在字的上方，挪一半回去，让字落在行的正中。
            let natural = font.ascender - font.descender + font.leading
            attributes[.baselineOffset] = max(0, (lineHeight - natural) / 2)
        }
        attributes[.paragraphStyle] = paragraph
        return NSAttributedString(string: text, attributes: attributes)
    }

    static let systemMeasure: Measure = { text, fontSize, weight, width, lineHeight in
        let string = attributedString(text, fontSize: fontSize, weight: weight, color: .black, alignment: .left, lineHeight: lineHeight)
        guard let width else {
            let size = string.size()
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }
        let rect = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}
