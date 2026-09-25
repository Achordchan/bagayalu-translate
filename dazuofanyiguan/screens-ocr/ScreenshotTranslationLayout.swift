import AppKit
import CoreText

/// 译文回贴的排版：每段译文放在哪、多大字号、怎么对齐、要抹掉哪块原文。
/// 纯计算，坐标是选区内的 pt、左上原点；量字宽的函数从外面传进来，方便单测。
///
/// 规则按「尽量像原图」排：
/// - 字号用原文的字号（渲染器按墨迹宽度反推出来，再把相近的归成一档），同样大的原文译出来也一样大。
/// - 译文只往空白处延伸，能延伸到哪由渲染器看像素定（`Limits`：碰到别的文字、图标、分隔线、色块边缘为止）。
/// - 单行：尽量一行放下，放不下先往空白处延伸、再小幅缩小（最多到 82%），然后折行往下占空白，
///   还不行就继续缩小（最多到 70%），最后截断。居中的（按钮、表格里居中的字）以原来的中心为准左右对称地延伸。
/// - 多行段落：在原段落的宽度里重排，行距跟原文，第一行和原文第一行对齐；段落外框里、短行旁边的图标或别的标签
///   （`Block.obstacles`）绕开排。放不下先往下占空白，再缩小（最多到 62%），最后截断。完整译文在「对照」里看。
/// - 最小字号不超过原字号：原文本来就很小（缩小的网页截图）时，宁可截断也不把字放大。
/// - 只抹原文所在的地方：译文延伸出去的地方本来就是空白，不动它，按钮、卡片的边也就不会被抹掉。
/// - 每段能延伸到哪是各自从原图量的，两段可能看中同一块空白（并排的两个居中标签都往中间长）。
///   排完再两两查，撞上了就把中间的空白分开重排，直到谁也不压着谁；两段原文的外框本来就叠在一起的
///   （段落短行旁边的标签落在段落外框里），让段落绕开标签的译文排。
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
        var limits: Limits
        /// 要绕开的地方（pt，选区坐标）：段落外框里短行旁边的图标、别的标签，往下长时挡在一部分宽度上的东西。
        var obstacles: [CGRect] = []

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

        func with(limits: Limits) -> Block {
            var block = self
            block.limits = limits
            return block
        }
    }

    /// 译文能占到的范围（pt）：左右、往下长到哪，以及上边界（上面紧挨着的东西；段落不往上长，
    /// 这里只管别让字身高的译文越过去）。
    struct Limits: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        /// 往下长（折行、段落变长）最多到哪，给下一段留着间距。
        var maxY: CGFloat
        var minY: CGFloat = 0
        /// 原来这一行的字身往下最多到哪（下面紧挨着的边，比如按钮的下沿）；nil 时同 `maxY`。
        /// 和 `maxY` 分开：留给下一段的间距是给往下长的译文用的，单行的字身只要别碰到下面的边。
        var bodyMaxY: CGFloat? = nil
    }

    struct Placement {
        let id: UUID
        let text: String
        let frame: CGRect
        let fontSize: CGFloat
        /// 多行时固定的行高；单行为 nil（用字体自然行高）。
        let lineHeight: CGFloat?
        /// 固定行高时把字挪到行中间的量（按译文本身的自然行高算）。
        var baselineOffset: CGFloat = 0
        let alignment: NSTextAlignment
        let weight: NSFont.Weight
        /// 要抹掉的范围：原文各行（各自外扩一点，盖住抗锯齿的边）。
        let eraseRects: [CGRect]
        /// 排字时要绕开的地方，相对 `frame` 左上角。
        var exclusions: [CGRect] = []
        /// 放不下、要截断时最多排几行（末行加省略号）；0 表示不限。
        var maximumLines = 0
    }

    /// 量出来的一段文字：排出来的大小，以及第一行墨迹的上下（相对文字左上角）。
    /// 墨迹要单独量：后备字体的字（缅甸文的元音符号叠在上面）在行框里不是居中的，拿行框估会偏。
    struct Measurement {
        var size: CGSize
        var inkTop: CGFloat
        var inkBottom: CGFloat
    }

    /// 量一段文字：`width` 为 nil 时不折行；`exclusions` 是要绕开的地方，相对文字左上角。
    typealias Measure = (
        _ text: String,
        _ fontSize: CGFloat,
        _ weight: NSFont.Weight,
        _ width: CGFloat?,
        _ lineHeight: CGFloat?,
        _ exclusions: [CGRect]
    ) -> Measurement

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
        var blocks = blocks.filter { !$0.lines.isEmpty && $0.fontSize > 0 }
        var placements = blocks.map { place($0, canvas: canvas, measure: measure) }
        // 限制只会越收越紧，最坏收到原文自己的范围，所以几轮之内一定停得下来。
        for _ in 0..<8 {
            var changed: Set<Int> = []
            for i in blocks.indices {
                for j in blocks.indices where j > i && collide(blocks[i], placements[i], blocks[j], placements[j]) {
                    if let (a, b) = separated(blocks[i], placements[i], blocks[j], placements[j]) {
                        if a.limits != blocks[i].limits { blocks[i] = a; changed.insert(i) }
                        if b.limits != blocks[j].limits { blocks[j] = b; changed.insert(j) }
                    } else {
                        // 外框叠在一起，从中间劈不开：行数多的那段（段落）绕开另一段的译文排。
                        let (host, guest) = blocks[i].lines.count >= blocks[j].lines.count ? (i, j) : (j, i)
                        let margin = 0.3 * min(blocks[i].fontSize, blocks[j].fontSize)
                        blocks[host].obstacles.append(placements[guest].frame.insetBy(dx: -margin, dy: 0))
                        changed.insert(host)
                    }
                }
            }
            guard !changed.isEmpty else { break }
            for index in changed {
                placements[index] = place(blocks[index], canvas: canvas, measure: measure)
            }
        }
        return placements
    }

    /// 两段译文的字有没有压在一起。行框上下各有一截行距的空白，只拿字身那一截比；
    /// 一段已经在绕开另一段的译文（外框叠在一起的那种），就不算撞。
    private static func collide(_ blockA: Block, _ a: Placement, _ blockB: Block, _ b: Placement) -> Bool {
        let bodyA = a.frame.insetBy(dx: 0, dy: 0.12 * a.fontSize)
        let bodyB = b.frame.insetBy(dx: 0, dy: 0.12 * b.fontSize)
        guard bodyA.intersects(bodyB) else { return false }
        let avoided = blockA.obstacles.contains { $0.contains(bodyB) } || blockB.obstacles.contains { $0.contains(bodyA) }
        return !avoided
    }

    /// 撞在一起的两段，把它们之间的空白分开：左右相邻的从两段原文正中间劈开；
    /// 上下相邻的（上面那段折行往下长，下面那段横着长过来，或者字身高的译文上下伸出来），
    /// 上面那段停在下面那段的译文之上，下面那段也不越过上面那段的译文。
    /// 两段原文本身就叠在一起（不该发生）时不管。
    private static func separated(_ a: Block, _ pa: Placement, _ b: Block, _ pb: Placement) -> (Block, Block)? {
        let boundsA = a.bounds, boundsB = b.bounds
        let margin = 0.3 * min(a.fontSize, b.fontSize)
        var limitsA = a.limits, limitsB = b.limits
        if boundsB.minX >= boundsA.maxX || boundsA.minX >= boundsB.maxX {
            let (left, right) = boundsA.minX < boundsB.minX ? (boundsA, boundsB) : (boundsB, boundsA)
            let middle = (left.maxX + right.minX) / 2
            if boundsA.minX < boundsB.minX {
                limitsA.maxX = min(limitsA.maxX, max(boundsA.maxX, middle - margin / 2))
                limitsB.minX = max(limitsB.minX, min(boundsB.minX, middle + margin / 2))
            } else {
                limitsB.maxX = min(limitsB.maxX, max(boundsB.maxX, middle - margin / 2))
                limitsA.minX = max(limitsA.minX, min(boundsA.minX, middle + margin / 2))
            }
        } else if boundsB.minY >= boundsA.maxY {
            limitsA.maxY = min(limitsA.maxY, max(boundsA.maxY, pb.frame.minY - margin))
            limitsA.bodyMaxY = min(limitsA.bodyMaxY ?? limitsA.maxY, max(boundsA.maxY, pb.frame.minY - margin))
            limitsB.minY = max(limitsB.minY, min(boundsB.minY, pa.frame.maxY + margin))
        } else if boundsA.minY >= boundsB.maxY {
            limitsB.maxY = min(limitsB.maxY, max(boundsB.maxY, pa.frame.minY - margin))
            limitsB.bodyMaxY = min(limitsB.bodyMaxY ?? limitsB.maxY, max(boundsB.maxY, pa.frame.minY - margin))
            limitsA.minY = max(limitsA.minY, min(boundsA.minY, pb.frame.maxY + margin))
        } else {
            return nil
        }
        return (a.with(limits: limitsA), b.with(limits: limitsB))
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
            maxY: min(canvas.height, max(block.limits.maxY, bounds.maxY)),
            minY: max(0, min(block.limits.minY, bounds.minY)),
            bodyMaxY: min(canvas.height, max(block.limits.bodyMaxY ?? block.limits.maxY, bounds.maxY))
        )
        let erase = block.lines.map { line in
            line.insetBy(dx: -0.12 * size, dy: -max(0.5, 0.08 * size))
                .intersection(CGRect(origin: .zero, size: canvas))
        }
        func placement(
            _ frame: CGRect,
            _ fontSize: CGFloat,
            lineHeight: CGFloat?,
            baselineOffset: CGFloat = 0,
            alignment: NSTextAlignment,
            exclusions: [CGRect] = [],
            maximumLines: Int = 0
        ) -> Placement {
            Placement(
                id: block.id,
                text: block.text,
                frame: frame,
                fontSize: fontSize,
                lineHeight: lineHeight,
                baselineOffset: baselineOffset,
                alignment: alignment,
                weight: block.weight,
                eraseRects: erase,
                exclusions: exclusions,
                maximumLines: maximumLines
            )
        }

        // 缩小的下限不低于 8pt，但也不高于原字号：原文本来就很小时，宁可截断也不放大。
        func shrinkFloor(_ ratio: CGFloat) -> CGFloat { min(size, max(8, size * ratio)) }
        let singleLineFloor = shrinkFloor(0.82)
        let wrapFloor = shrinkFloor(0.7)
        // 段落宁可再小一点也别截断：截掉的是整句话，单行截掉的多半只是个尾巴。
        let paragraphFloor = shrinkFloor(0.62)

        if block.lines.count == 1 {
            let line = block.lines[0]
            // 同一行里要绕开的东西（别的段的译文）：左右最多长到它跟前。它下面的交给折行时绕开。
            var limits = limits
            /// 一行译文：墨迹的竖直中心对准原文墨迹的中心。
            struct Candidate {
                var frame: CGRect
                var ink: ClosedRange<CGFloat>
            }
            /// 译文的墨迹要落在上下边界里（选区边、按钮的上下沿、上下紧挨着的东西）：放不下就往下或往上挪，
            /// 挪了也放不下返回 nil。墨迹高的文字（缅甸文、高棉文）会因此缩小。
            func fitVertically(_ candidate: Candidate) -> CGRect? {
                let floorY = limits.bodyMaxY ?? limits.maxY
                let ink = candidate.ink
                guard ink.upperBound - ink.lowerBound <= floorY - limits.minY + 0.5 else { return nil }
                if ink.lowerBound < limits.minY { return candidate.frame.offsetBy(dx: 0, dy: limits.minY - ink.lowerBound) }
                if ink.upperBound > floorY { return candidate.frame.offsetBy(dx: 0, dy: floorY - ink.upperBound) }
                return candidate.frame
            }
            for obstacle in block.obstacles where obstacle.minY < line.maxY && obstacle.maxY > line.minY {
                if obstacle.minX >= line.maxX - 1 {
                    limits.maxX = max(line.maxX, min(limits.maxX, obstacle.minX))
                } else if obstacle.maxX <= line.minX + 1 {
                    limits.minX = min(line.minX, max(limits.minX, obstacle.maxX))
                }
            }
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

            // 行高、墨迹都按译文本身量：换了后备字体的文字（缅甸文、高棉文、藏文）一行比「Ag字」高得多，
            // 墨迹在行框里也不居中。`width` 为 nil 时按译文自然宽度排一行。
            func singleLine(_ fontSize: CGFloat, width: CGFloat?) -> Candidate {
                let natural = measure(block.text, fontSize, block.weight, nil, nil, [])
                let width = width ?? natural.size.width + 1
                let x: CGFloat
                switch block.alignment {
                case .center: x = line.midX - width / 2
                case .right: x = line.maxX - width
                default: x = line.minX
                }
                let top = line.midY - (natural.inkTop + natural.inkBottom) / 2
                return Candidate(
                    frame: CGRect(x: x, y: top, width: width, height: natural.size.height),
                    ink: (top + natural.inkTop)...(top + natural.inkBottom)
                )
            }
            func fitsOnOneLine(_ fontSize: CGFloat) -> Bool {
                measure(block.text, fontSize, block.weight, nil, nil, []).size.width <= maxWidth
            }

            // 1. 一行放下（横竖都放得下），最多缩到 82%。
            for fontSize in sizes(from: size, downTo: singleLineFloor) where fitsOnOneLine(fontSize) {
                if let frame = fitVertically(singleLine(fontSize, width: nil)) {
                    return placement(frame, fontSize, lineHeight: nil, alignment: block.alignment)
                }
            }
            // 2. 折行往下占空白（绕开下面零星的东西），最多缩到 70%。第一行的墨迹越过上边界就整块往下挪。
            for fontSize in sizes(from: size, downTo: wrapFloor) {
                let first = singleLine(fontSize, width: maxWidth)
                let frame0 = first.ink.lowerBound < limits.minY
                    ? first.frame.offsetBy(dx: 0, dy: limits.minY - first.ink.lowerBound)
                    : first.frame
                let local = block.obstacles.map { $0.offsetBy(dx: -frame0.minX, dy: -frame0.minY) }
                let height = measure(block.text, fontSize, block.weight, maxWidth, nil, local).size.height
                if frame0.minY + height <= limits.maxY {
                    let frame = CGRect(x: frame0.minX, y: frame0.minY, width: maxWidth, height: height)
                    return placement(frame, fontSize, lineHeight: nil, alignment: block.alignment, exclusions: local)
                }
            }
            // 3. 一行、缩到 70%。
            for fontSize in sizes(from: singleLineFloor, downTo: wrapFloor) where fitsOnOneLine(fontSize) {
                if let frame = fitVertically(singleLine(fontSize, width: nil)) {
                    return placement(frame, fontSize, lineHeight: nil, alignment: block.alignment)
                }
            }
            // 4. 还放不下：截断成一行。竖着放不下（墨迹高的文字在矮按钮里）就接着缩，最小 8pt（也不超过原字号）；
            //    8pt 还放不下只能居中，再小就看不清了。
            for fontSize in sizes(from: wrapFloor, downTo: min(size, 8)) {
                let width = fitsOnOneLine(fontSize) ? nil : maxWidth
                if let frame = fitVertically(singleLine(fontSize, width: width)) {
                    return placement(frame, fontSize, lineHeight: nil, alignment: block.alignment, maximumLines: 1)
                }
            }
            let last = singleLine(min(size, 8), width: maxWidth)
            return placement(last.frame, min(size, 8), lineHeight: nil, alignment: block.alignment, maximumLines: 1)
        }

        // 多行段落：在原宽度里重排，行距跟原文。
        let width = bounds.width
        let pitch = block.pitch ?? size * 1.4
        /// 一种字号下的排法：行高跟原文的行距，但不小于译文本身（TextKit 实测）的自然行高——缅甸文、高棉文这类
        /// 后备字体高的文字，按原文行距排会压到上下行。字挪到行中间的量也按译文本身算。
        /// 第一行的字身越过上边界时整段往下挪。
        func layout(_ fontSize: CGFloat) -> (frame: CGRect, lineHeight: CGFloat, offset: CGFloat, exclusions: [CGRect]) {
            let single = measure(block.text, fontSize, block.weight, nil, nil, [])
            let natural = single.size.height
            let lineHeight = max(natural, min(max(pitch * fontSize / size, 1.12 * fontSize), 1.9 * fontSize))
            let offset = max(0, (lineHeight - natural) / 2)
            // 第一行的墨迹中心对准原文第一行的墨迹中心；墨迹越过上边界就整段往下挪。
            var top = block.lines[0].midY - offset - (single.inkTop + single.inkBottom) / 2
            let firstInkTop = top + offset + single.inkTop
            if firstInkTop < limits.minY {
                top += limits.minY - firstInkTop
            }
            // TextKit 按整个行框（连上下的行距）判断碰没碰到绕开的地方，字身只占中间一截。先把绕开的地方
            // 上下各收进行距多出来的那一半，等于拿字身去比：擦着行距的障碍不会把一整行劈成两截，
            // 整个落在两行之间空当里的就不用绕。
            let local = block.obstacles
                .map { $0.insetBy(dx: 0, dy: offset).offsetBy(dx: -bounds.minX, dy: -top) }
                .filter { !$0.isNull && $0.height > 0 }
            let height = measure(block.text, fontSize, block.weight, width, lineHeight, local).size.height
            return (CGRect(x: bounds.minX, y: top, width: width, height: height), lineHeight, offset, local)
        }
        for fontSize in sizes(from: size, downTo: paragraphFloor) {
            let candidate = layout(fontSize)
            if candidate.frame.maxY <= limits.maxY {
                return placement(
                    candidate.frame,
                    fontSize,
                    lineHeight: candidate.lineHeight,
                    baselineOffset: candidate.offset,
                    alignment: block.alignment,
                    exclusions: candidate.exclusions
                )
            }
        }
        let last = layout(paragraphFloor)
        let height = max(last.lineHeight, limits.maxY - last.frame.minY)
        return placement(
            CGRect(x: last.frame.minX, y: last.frame.minY, width: width, height: height),
            paragraphFloor,
            lineHeight: last.lineHeight,
            baselineOffset: last.offset,
            alignment: block.alignment,
            exclusions: last.exclusions,
            maximumLines: max(1, Int((height + 0.01) / last.lineHeight))
        )
    }

    /// 排版和绘制共用同一份文字属性，量出来的大小才和画出来的一致。
    static func attributedString(
        _ text: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment,
        lineHeight: CGFloat?,
        baselineOffset: CGFloat? = nil
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            // 固定行高时多出来的空间默认全堆在字的上方，挪一半回去，让字落在行的正中。挪多少按译文本身的
            // 自然行高算（排版时量好的 `baselineOffset`），后备字体高的文字不能按主字体估；只量高度时没给，按主字体估。
            let natural = font.ascender - font.descender + font.leading
            attributes[.baselineOffset] = baselineOffset ?? max(0, (lineHeight - natural) / 2)
        }
        attributes[.paragraphStyle] = paragraph
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// 不折行也用 TextKit 量：画的时候用的就是它。行高要算上后备字体——缅甸文、高棉文一行比系统字体高出近一倍，
    /// `NSAttributedString.size()` 却只按主字体算，拿它定行框，译文会溢出、竖直位置也偏。
    static let systemMeasure: Measure = { text, fontSize, weight, width, lineHeight, exclusions in
        let string = attributedString(text, fontSize: fontSize, weight: weight, color: .black, alignment: .left, lineHeight: lineHeight)
        let layout = TextLayout(string, size: CGSize(width: width ?? 100_000, height: 100_000), exclusions: exclusions)
        let used = layout.usedRect
        let ink = layout.firstLineInk ?? (0.15 * used.height, 0.85 * used.height)
        return Measurement(size: CGSize(width: ceil(used.maxX), height: ceil(used.maxY)), inkTop: ink.top, inkBottom: ink.bottom)
    }

    /// TextKit 排出来的一段文字。量和画用同一套排法，量出来的才和画出来的一致；绕开区域、末行截断也靠它。
    /// 可以在后台线程用：头文件要求别的线程访问时关掉后台排版。一个实例只在一个线程里用。
    final class TextLayout {
        private let storage: NSTextStorage
        private let manager = NSLayoutManager()
        private let container: NSTextContainer

        init(_ string: NSAttributedString, size: CGSize, exclusions: [CGRect] = [], maximumLines: Int = 0) {
            storage = NSTextStorage(attributedString: string)
            container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            container.exclusionPaths = exclusions.map { NSBezierPath(rect: $0) }
            container.maximumNumberOfLines = maximumLines
            if maximumLines > 0 {
                container.lineBreakMode = .byTruncatingTail
            }
            manager.backgroundLayoutEnabled = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }

        var usedRect: CGRect { manager.usedRect(for: container) }

        /// 字是不是都排进去了（容器太矮时 TextKit 会整行不排）。
        var laysOutEverything: Bool {
            manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil).length == storage.length
        }

        /// 第一行墨迹的上下（相对左上角）：字形轮廓用 Core Text 量（整段当一行量，取所有字里最高最低的，
        /// 只会偏保守），基线位置取 TextKit 实际排出来的。没有字时为 nil。
        var firstLineInk: (top: CGFloat, bottom: CGFloat)? {
            guard storage.length > 0, manager.numberOfGlyphs > 0 else { return nil }
            let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let baseline = fragment.minY + manager.location(forGlyphAt: 0).y
            let bounds = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(storage), .useGlyphPathBounds)
            guard !bounds.isNull, bounds.height > 0 else { return nil }
            return (baseline - bounds.maxY, baseline - bounds.minY)
        }

        /// 每一行实际占到的范围（相对左上角）。
        var lineRects: [CGRect] {
            var rects: [CGRect] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
                rects.append(used)
            }
            return rects
        }

        /// 画在当前图形上下文里（要求是翻转的坐标系，左上原点）。
        func draw(at origin: CGPoint) {
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: origin)
        }
    }
}
