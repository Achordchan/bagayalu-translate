import AppKit
import CoreGraphics
import CoreText
import Foundation

/// 截图翻译的回贴：像微信截图翻译那样，保留原截图，只抹掉要翻译的原文，
/// 再按原位置、原字号、原颜色画上译文。原图里的背景、按钮、配色都还在。
///
/// 纯计算、不碰界面，可以放在后台跑：像素在自己的缓冲区里改，文字画进自己建的图形上下文
/// （AppKit 的字符串绘制在各线程自己的上下文里是安全的）。
/// 没列进 `translations` 的段落（不用翻、还没翻完、翻译失败），以及译文和原文一样的段落，一个像素都不动。
enum ScreenshotTranslationRenderer {
    struct Input {
        let image: CGImage
        /// 选区大小（pt）。截图的像素尺寸是它的整数倍左右（Retina 下是 2 倍）。
        let pointSize: CGSize
        let blocks: [VisionOCRService.OCRBlock]
        /// 段落 → 译文。
        let translations: [UUID: String]
        /// 同一张截图、同一批识别结果多次渲染时传同一个，量过的样式不再重量。
        var cache: StyleCache? = nil
    }

    /// 量样式只看原图，结果可以跨次渲染复用：翻译进行中每翻完一批都要整张重画一次。
    /// 按段落 id 存（每次识别的 id 都是新的）。不加锁：同一时间只能有一个渲染在用它。
    final class StyleCache {
        fileprivate var styles: [UUID: MeasuredStyle] = [:]
        /// 不重画的段落各行墨迹占的地方（pt），抹字时要护住。
        fileprivate var inks: [UUID: [CGRect]] = [:]

        init() {}
    }

    static func render(_ input: Input) -> CGImage? {
        guard input.pointSize.width > 0, input.pointSize.height > 0,
              var pixels = PixelBuffer(image: input.image) else { return nil }
        let redrawn = input.blocks.filter { block in
            guard !block.lines.isEmpty, let translation = input.translations[block.id] else { return false }
            let normalized = normalizedText(translation)
            return !normalized.isEmpty && normalized != normalizedText(block.text)
        }
        guard !redrawn.isEmpty else { return input.image }

        // 先量完所有段落的样式和空白再动像素：抹掉一段会改变旁边段落看到的背景。
        let scale = CGFloat(pixels.width) / input.pointSize.width
        let styles = redrawn.map { block -> MeasuredStyle in
            if let cached = input.cache?.styles[block.id] { return cached }
            let style = measureStyle(of: block, in: pixels, scale: scale)
            input.cache?.styles[block.id] = style
            return style
        }
        // 不重画的段落（没有译文、译文和原文一样）的字要护住：行距紧时，要翻的那段往外扩的墨迹带、抹字的外扩，
        // 可能伸到它们的字上（分段时句末标点、下一行大写开头都会断成两段）。只量挨着要抹的地方的那些。
        let redrawnIDs = Set(redrawn.map(\.id))
        let eraseAreas = styles.flatMap(\.eraseRects).map { $0.insetBy(dx: -2, dy: -2) }
        let protected = input.blocks.filter { !redrawnIDs.contains($0.id) && !$0.lines.isEmpty }.flatMap { block -> [CGRect] in
            let bounds = CGRect(
                x: block.boundingBox.minX * input.pointSize.width,
                y: (1 - block.boundingBox.maxY) * input.pointSize.height,
                width: block.boundingBox.width * input.pointSize.width,
                height: block.boundingBox.height * input.pointSize.height
            )
            guard eraseAreas.contains(where: { $0.intersects(bounds) }) else { return [] }
            if let cached = input.cache?.inks[block.id] { return cached }
            let rects = block.lines.map { line -> CGRect in
                let rect = lineInk(of: line, in: pixels).rect
                return CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale)
            }
            input.cache?.inks[block.id] = rects
            return rects
        }

        // 抹字、墨迹带、能占到的范围都按不重画的段落收紧。每次渲染重算、不进缓存：哪些段落不重画，每翻完一批都在变。
        let retained = styles.map { retain($0, around: protected, margin: 1 / scale) }

        let fontSizes = ScreenshotTranslationLayout.harmonizedFontSizes(styles.map(\.fontSize))
        let layoutBlocks = redrawn.indices.map { index in
            ScreenshotTranslationLayout.Block(
                id: redrawn[index].id,
                // 段落是一整块重排的，引擎自己加的换行、多余的空格都不要。
                text: normalizedText(input.translations[redrawn[index].id] ?? redrawn[index].text),
                lines: retained[index].lines,
                fontSize: fontSizes[index],
                weight: retained[index].weight,
                alignment: retained[index].alignment,
                limits: retained[index].limits,
                obstacles: retained[index].obstacles,
                eraseRects: retained[index].eraseRects
            )
        }
        let placements = ScreenshotTranslationLayout.plan(layoutBlocks, canvas: input.pointSize)

        var colors: [UUID: NSColor] = [:]
        for (block, style) in zip(redrawn, styles) {
            colors[block.id] = pixels.color(style.textColor)
        }
        let backgrounds = Dictionary(uniqueKeysWithValues: zip(redrawn.map(\.id), styles.map(\.background)))
        for placement in placements {
            for rect in placement.eraseRects {
                pixels.erase(
                    CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale),
                    fallback: backgrounds[placement.id] ?? PixelBuffer.RGB(r: 255, g: 255, b: 255)
                )
            }
        }

        return pixels.makeImage(scale: scale) {
            for placement in placements {
                let string = ScreenshotTranslationLayout.attributedString(
                    placement.text,
                    fontSize: placement.fontSize,
                    weight: placement.weight,
                    color: colors[placement.id] ?? .black,
                    alignment: placement.alignment,
                    lineHeight: placement.lineHeight,
                    baselineOffset: placement.baselineOffset
                )
                // 横着只画在排好的框里（左右各多留一个像素给字形出头）：连一个字都放不下的极端情况，TextKit 会让字伸出容器，
                // 不能画到旁边的分隔线、图标、别的段落上。竖着不裁：后备字体的字可能比行框高。
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(
                    x: placement.frame.minX - 1 / scale,
                    y: -input.pointSize.height,
                    width: placement.frame.width + 2 / scale,
                    height: 3 * input.pointSize.height
                )).addClip()
                ScreenshotTranslationLayout.TextLayout(
                    string,
                    size: placement.frame.size,
                    exclusions: placement.exclusions,
                    maximumLines: placement.maximumLines
                ).draw(at: placement.frame.origin)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// 不重画的段落的字（`protected`，pt；四周多留 `margin` 给抗锯齿的边），要重画的这一段处处都要让开：
    /// - 抹字范围不越过它们；
    /// - 墨迹带不越过它们：字碰在一起时墨迹带扩进了别人的字，按它排，译文的中心会跟着偏、画到别人身上；
    /// - 排译文时也不越过：在上面、下面的收紧上下边界（只管横着够得着的：译文左右长不到的地方，上下有什么都碍不着）。
    ///   同一行左右挨着的，扫描扫到它的字就停了，左右本来就长不过去；排版时上下边界也不会收进这一行自己的墨迹带。
    static func retain(_ style: MeasuredStyle, around protected: [CGRect], margin: CGFloat) -> MeasuredStyle {
        guard !protected.isEmpty, !style.lines.isEmpty else { return style }
        let guarded = protected.map { $0.insetBy(dx: -margin, dy: -margin) }
        var style = style
        style.eraseRects = zip(style.eraseRects, style.lines).compactMap { rect, line in
            let rect = trimmed(rect, line: line, against: guarded)
            return rect.width > 0 && rect.height > 0 ? rect : nil
        }
        style.lines = style.lines.map { line in
            let rect = trimmed(line, line: line, against: guarded)
            return rect.width > 0 && rect.height > 0 ? rect : line
        }
        let first = style.lines[0], last = style.lines[style.lines.count - 1]
        for other in guarded where other.maxX > style.limits.minX && other.minX < style.limits.maxX {
            if other.midY > last.midY {
                let bottom = boundary(below: last, other)
                style.limits.maxY = min(style.limits.maxY, bottom)
                style.limits.bodyMaxY = min(style.limits.bodyMaxY ?? style.limits.maxY, bottom)
            } else if other.midY < first.midY {
                style.limits.minY = max(style.limits.minY, boundary(above: first, other))
            }
        }
        return style
    }

    /// 把 `rect`（`line` 这一行的抹字范围或墨迹带）从 `guarded` 上削掉，不削进这一行自己的墨迹：横着不重叠的是并排
    /// （同一行上挨着的另一段），削左右；横着重叠的是上下叠着的，削到分界。不能按竖着重叠多少来分：
    /// 字碰在一起时两行的墨迹带互相扩进对方，竖着能叠一大半。
    static func trimmed(_ rect: CGRect, line: CGRect, against guarded: [CGRect]) -> CGRect {
        var rect = rect
        for other in guarded where rect.intersects(other) {
            if other.minX >= line.maxX {
                rect.size.width = max(0, min(rect.maxX, other.minX) - rect.minX)
            } else if other.maxX <= line.minX {
                let minX = max(rect.minX, other.maxX)
                rect = CGRect(x: minX, y: rect.minY, width: max(0, rect.maxX - minX), height: rect.height)
            } else if other.midY > line.midY {
                rect.size.height = max(0, min(rect.maxY, boundary(below: line, other)) - rect.minY)
            } else {
                let minY = max(rect.minY, boundary(above: line, other))
                rect = CGRect(x: rect.minX, y: minY, width: rect.width, height: max(0, rect.maxY - minY))
            }
        }
        return rect
    }

    /// 这一行和它下面（上面）一段不重画的字之间的分界：中间隔着空白就是对方墨迹的边；字碰在一起（墨迹带叠着）时，
    /// 交界处的像素分不清是谁的，按两行墨迹的中线分，各让一半。
    private static func boundary(below line: CGRect, _ other: CGRect) -> CGFloat {
        other.minY >= line.maxY ? other.minY : (line.midY + other.midY) / 2
    }

    private static func boundary(above line: CGRect, _ other: CGRect) -> CGFloat {
        other.maxY <= line.minY ? other.maxY : (line.midY + other.midY) / 2
    }

    /// 比较译文和原文时忽略空白的差别。
    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - 量原文样式

    struct MeasuredStyle {
        /// 每一行墨迹的范围（pt）。
        var lines: [CGRect]
        var fontSize: CGFloat
        var textColor: PixelBuffer.RGB
        var background: PixelBuffer.RGB
        var weight: NSFont.Weight
        /// 笔画宽度是同条件下常规体的几倍（判断粗细用）；量不出来为 nil。
        var strokeRatio: CGFloat?
        var alignment: NSTextAlignment
        /// 译文能延伸到的空白（pt）。
        var limits: ScreenshotTranslationLayout.Limits
        /// 排译文时要绕开的东西（pt）：段落外框里各行旁边的，以及往下长时挡在一部分竖条上的。
        var obstacles: [CGRect]
        /// 要抹掉的范围（pt）：各行墨迹外扩一点，但不越过旁边量到的东西。
        var eraseRects: [CGRect]
    }

    /// 按笔画宽度（覆盖率算的每段宽度取中位数，见 `PixelBuffer.inkBand`）是同条件下常规体的几倍定字重。
    /// 2026-09-26 在 macOS 26.5 上实测（英、中、日、韩和按钮上的短标签 × 11～28pt × 四种字重 × 深浅色，1 倍、2 倍屏各 200 组）：
    /// 2 倍屏常规 0.99～1.02，中等 1.13～1.20，半粗 1.23～1.31（短词「Install」28pt 有一组 1.72），粗体 1.34～1.93；
    /// 1 倍屏常规 0.91～1.13，中等 1.09～1.24，半粗 1.17～1.36，粗体 1.26～1.91。
    /// 常规体两种倍率下都一组没判错；中等字重介于两者之间，判成常规或半粗都有；半粗和粗体在 1 倍屏上偶尔互相认错（字号差 2% 左右）。
    static func weight(forStrokeRatio ratio: CGFloat?) -> NSFont.Weight {
        guard let ratio else { return .regular }
        if ratio >= 1.33 { return .bold }
        if ratio >= 1.15 { return .semibold }
        return .regular
    }

    /// 一行字的墨迹（像素）：Vision 的行框、按字宽粗估的字号、背景色、文字色、墨迹带，和墨迹的左右端（`inkBox`，上下还是行框的）。
    struct LineInk {
        var box: CGRect
        var estimate: CGFloat
        var background: PixelBuffer.RGB
        var ink: PixelBuffer.RGB
        var band: PixelBuffer.InkBand
        var inkBox: CGRect

        /// 墨迹占的地方：左右是墨迹的左右端，上下是墨迹带。
        var rect: CGRect {
            CGRect(x: inkBox.minX, y: band.top, width: inkBox.width, height: max(1, band.bottom - band.top))
        }
    }

    static func lineInk(of line: VisionOCRService.OCRLine, in pixels: PixelBuffer) -> LineInk {
        let box = CGRect(
            x: line.boundingBox.minX * CGFloat(pixels.width),
            y: (1 - line.boundingBox.maxY) * CGFloat(pixels.height),
            width: line.boundingBox.width * CGFloat(pixels.width),
            height: line.boundingBox.height * CGFloat(pixels.height)
        )
        // 字号按字宽量（Vision 的行框高度会忽高忽低，见 OCRParagraphGrouper）：先按平均字宽粗估，
        // 再量出这行墨迹实际的左右端，用系统字体排同样的字、按墨迹宽度反推——行框两头的留白忽多忽少
        // （按钮上的两个字能多出一成多），大字号的 SF 字形又更紧凑，只按行框和平均字宽估都会偏。
        let estimate = max(OCRParagraphGrouper.estimatedEm(width: box.width, text: line.text), 4)
        let background = pixels.ringMedian(around: box, padding: max(2, 0.15 * estimate))
        let ink = pixels.inkColor(in: box, background: background)
        var band = pixels.inkBand(in: box, background: background, ink: ink, em: estimate)
        var inkBox = box
        if let extent = pixels.inkExtent(in: box, top: band.top, bottom: band.bottom, background: background, ink: ink, slack: 0.15 * estimate, em: estimate) {
            inkBox = CGRect(x: extent.minX, y: box.minY, width: extent.maxX - extent.minX, height: box.height)
            // 行框里夹着紧贴着字的分隔线时，它每一行都有颜色，会把墨迹带一路撑到搜索范围的边上（段落里还会撑进相邻的行），
            // 笔画宽度也被它的细线拉低。只在墨迹的左右端之间重量一次墨迹带，再按新的带重量一次左右端。
            band = pixels.inkBand(in: inkBox, background: background, ink: ink, em: estimate)
            if let refined = pixels.inkExtent(in: inkBox, top: band.top, bottom: band.bottom, background: background, ink: ink, slack: 0, em: estimate) {
                inkBox = CGRect(x: refined.minX, y: box.minY, width: refined.maxX - refined.minX, height: box.height)
            }
        }
        return LineInk(box: box, estimate: estimate, background: background, ink: ink, band: band, inkBox: inkBox)
    }

    static func measureStyle(of block: VisionOCRService.OCRBlock, in pixels: PixelBuffer, scale: CGFloat) -> MeasuredStyle {
        var boxes: [CGRect] = []
        var bands: [PixelBuffer.InkBand] = []
        var ems: [CGFloat] = []
        var inks: [PixelBuffer.RGB] = []
        var backgrounds: [PixelBuffer.RGB] = []

        for line in block.lines {
            let measured = lineInk(of: line, in: pixels)
            // 按 pt 量：SF 按字号换字形，拿像素当字号量（2 倍屏上 13pt 当成 26pt）会换成大号字形、量偏。
            let em = fittedFontSize(of: line.text, inkWidth: measured.inkBox.width / scale, estimate: measured.estimate / scale) * scale
            boxes.append(measured.inkBox)
            bands.append(measured.band)
            ems.append(em)
            inks.append(measured.ink)
            backgrounds.append(measured.background)
        }

        let ink = PixelBuffer.RGB.median(inks)
        let background = PixelBuffer.RGB.median(backgrounds)
        let lines = zip(boxes, bands).map { box, band in
            CGRect(x: box.minX, y: band.top, width: box.width, height: max(1, band.bottom - band.top))
        }
        // 粗细和「同样字号、同样颜色的常规体」比：笔画宽度随书写系统、字号、深浅色都会变
        // （浅字深底的抗锯齿显得更粗），中文常规体就比英文粗体还粗，定一个绝对阈值分不开。
        let longest = block.lines.indices.max { boxes[$0].width < boxes[$1].width } ?? 0
        let strokeRatio: CGFloat? = bands[longest].strokeWidth.flatMap { measured in
            regularStrokeWidth(
                of: block.lines[longest].text,
                fontSize: ems[longest] / scale,
                scale: scale,
                ink: inks[longest],
                background: backgrounds[longest],
                colorSpace: pixels.colorSpace
            ).map { measured / $0 }
        }
        let weight = weight(forStrokeRatio: strokeRatio)
        // 粗体比常规体宽，按实际要画的字重重新反推一次字号，译文才和原文一样大。
        if weight != .regular {
            for index in ems.indices {
                ems[index] = fittedFontSize(of: block.lines[index].text, inkWidth: boxes[index].width / scale, estimate: ems[index] / scale, weight: weight) * scale
            }
        }

        let em = median(ems)

        // 译文能往外占到哪：碰到「东西」为止（见 `PixelBuffer.scanColumns`）。
        let noise = pixels.ringNoise(around: boxes[0], padding: max(2, 0.15 * em), median: background)
        let bounds = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
        var alignment = NSTextAlignment.left
        var minX = bounds.minX, maxX = bounds.maxX

        // 扫描从墨迹外面开始：突变是拿这一列和两列之前比的，两列都得在墨迹（连同抗锯齿的边）外面，
        // 否则 1 倍屏上的小字（0.15 个字宽才一个多像素）会把自己最后一笔竖画当成障碍。
        let clearance = max(0.15 * em, 2)
        if lines.count == 1 {
            let box = boxes[0]
            let rows = pixels.clampedRows(Int(box.midY - 0.6 * em)...Int(box.midY + 0.6 * em))
            let reach = Int(40 * em)
            let rightStart = Int((box.maxX + clearance).rounded(.up)) + 2
            let leftStart = Int((box.minX - clearance).rounded(.down)) - 3
            var right = pixels.scanColumns(from: rightStart, step: 1, limit: reach, rows: rows, background: background, noise: noise)
            var left = pixels.scanColumns(from: leftStart, step: -1, limit: reach, rows: rows, background: background, noise: noise)
            // 起点前面跳过的那一小段留白里，紧挨着字的分隔线（1 倍屏上离字一两个像素）。
            let band = (top: Int(bands[0].top), bottom: Int(bands[0].bottom))
            let probe = max(3, Int(0.35 * em))
            let above = band.top - 2 - probe >= 0 ? (band.top - 2 - probe)...(band.top - 2) : nil
            let below = band.bottom + 1 + probe < pixels.height ? (band.bottom + 1)...(band.bottom + 1 + probe) : nil
            if Int(box.maxX) < rightStart,
               let x = pixels.dividerColumn(in: Array(Int(box.maxX)..<rightStart), above: above, below: below, background: background, noise: noise) {
                right = (x, true)
            }
            if leftStart + 1 < Int(box.minX),
               let x = pixels.dividerColumn(in: Array(((leftStart + 1)..<Int(box.minX)).reversed()), above: above, below: below, background: background, noise: noise) {
                left = (x, true)
            }
            let margin = 0.3 * em
            maxX = max(box.maxX, CGFloat(right.stop) - margin)
            minX = min(box.minX, CGFloat(left.stop + 1) + margin)
            // 两边都碰到了实实在在的边、而且离两边一样远：按钮、居中的单元格。只碰到选区边缘、
            // 或者只是渐变走远了的不算，否则框选时恰好框得对称，左对齐的一行也会被当成居中。
            let gapLeft = box.minX - CGFloat(left.stop), gapRight = CGFloat(right.stop) - box.maxX
            if left.hitEdge, right.hitEdge, abs(gapLeft - gapRight) <= max(0.6 * em, 0.15 * (gapLeft + gapRight)) {
                alignment = .center
            }
        } else {
            let tolerance = 0.6 * em
            if spread(lines.map(\.minX)) <= tolerance {
                alignment = .left
            } else if spread(lines.map(\.midX)) <= tolerance {
                alignment = .center
            } else if spread(lines.map(\.maxX)) <= tolerance {
                alignment = .right
            }
        }

        // 段落外框里、每行左右的空当也要查：第一行长、第二行短时，短行旁边可能是图标或别的标签，
        // 重排时绕开它（整行剩下的部分都算占用，宁可保守）。
        // 绕开的地方左右留 0.3 个字宽；上下只留 0.1 个字宽——TextKit 按整行的行框（连行距）判断，
        // 上下留多了，障碍下面那一行也会被劈成两截。
        let sideMargin = 0.3 * em, edgeMargin = 0.1 * em
        var obstacles: [CGRect] = []
        if lines.count > 1 {
            for line in lines {
                let rows = pixels.clampedRows(Int(line.minY)...Int(line.maxY))
                let top = line.minY - 0.15 * em, height = line.height + 0.3 * em
                let rightStart = Int((line.maxX + clearance).rounded(.up)) + 2
                if rightStart < Int(bounds.maxX) {
                    let hit = pixels.scanColumns(from: rightStart, step: 1, limit: Int(bounds.maxX) - rightStart + 1, rows: rows, background: background, noise: noise)
                    if hit.hitEdge, CGFloat(hit.stop) <= bounds.maxX {
                        let x = CGFloat(hit.stop) - sideMargin
                        obstacles.append(CGRect(x: x, y: top, width: bounds.maxX - x, height: height))
                    }
                }
                let leftStart = Int((line.minX - clearance).rounded(.down)) - 3
                if leftStart > Int(bounds.minX) {
                    let hit = pixels.scanColumns(from: leftStart, step: -1, limit: leftStart - Int(bounds.minX) + 1, rows: rows, background: background, noise: noise)
                    if hit.hitEdge, CGFloat(hit.stop) >= bounds.minX {
                        let x = CGFloat(hit.stop + 1) + sideMargin
                        obstacles.append(CGRect(x: bounds.minX, y: top, width: x - bounds.minX, height: height))
                    }
                }
            }
        }

        // 往下：按竖条（每条两个字宽）各自往下扫。多数竖条碰到东西的地方（下一段、分隔线）是底线，
        // 碰到下一段时给它留出至少一半原有的间距，不然译文和下一段贴在一起，段落就分不清了；
        // 只有少数竖条早早碰到的（段落右下角的图标），当成绕开的地方，不让它把整段都挡住。
        let columns = pixels.clampedColumns(Int(minX)...Int(maxX))
        let startRow = Int((bounds.maxY + clearance).rounded(.up)) + 2
        // 起点上面跳过的那几行里，紧挨着字的横分隔线：在字的左右两头都连着才算。
        let sideProbe = max(3, Int(0.35 * em))
        let leftSide = Int(bounds.minX) - 2 - sideProbe >= 0 ? (Int(bounds.minX) - 2 - sideProbe)...(Int(bounds.minX) - 2) : nil
        let rightSide = Int(bounds.maxX) + 1 + sideProbe < pixels.width ? (Int(bounds.maxX) + 1)...(Int(bounds.maxX) + 1 + sideProbe) : nil
        let dividerBelow = Int(bounds.maxY) < startRow
            ? pixels.dividerRow(in: Array(Int(bounds.maxY)..<startRow), left: leftSide, right: rightSide, background: background, noise: noise)
            : nil
        let stripe = max(4, Int(2 * em))
        let stripes = stride(from: columns.lowerBound, through: columns.upperBound, by: stripe).map { x -> (columns: ClosedRange<Int>, stop: Int, hitEdge: Bool) in
            let range = x...min(columns.upperBound, x + stripe - 1)
            let scan = pixels.scanRows(from: startRow, step: 1, limit: Int(20 * em), columns: range, background: background, noise: noise)
            return (range, scan.stop, scan.hitEdge)
        }
        var floorStripe = stripes.sorted { $0.stop < $1.stop }[stripes.count / 2]
        if let row = dividerBelow {
            floorStripe = (columns, row, true)
        }
        let gapBelow = CGFloat(floorStripe.stop) - bounds.maxY
        let maxY = floorStripe.hitEdge
            ? max(bounds.maxY, CGFloat(floorStripe.stop) - max(0.3 * em, 0.5 * gapBelow))
            : min(CGFloat(pixels.height) - 0.2 * em, CGFloat(floorStripe.stop))
        // 往上：第一行上面紧挨着的东西（上一段、按钮的上沿、选区边）。段落不往上长，
        // 这里只用来别让字身高的译文（缅甸文、高棉文）越过去。
        let aboveStart = Int((bounds.minY - clearance).rounded(.down)) - 3
        var aboveScan = pixels.scanRows(from: aboveStart, step: -1, limit: Int(3 * em), columns: columns, background: background, noise: noise)
        if aboveStart + 1 < Int(bounds.minY),
           let row = pixels.dividerRow(in: Array(((aboveStart + 1)..<Int(bounds.minY)).reversed()), left: leftSide, right: rightSide, background: background, noise: noise) {
            aboveScan = (row, true)
        }
        let minY = aboveScan.hitEdge
            ? min(bounds.minY, CGFloat(aboveScan.stop + 1) + 0.1 * em)
            : max(0, CGFloat(aboveScan.stop + 1))
        // 原来这一行的字身往下最多到哪：下面最近的边（任何一条竖条碰到的最高处），只留 0.1 个字宽。
        var nearestBelow = stripes.min { $0.stop < $1.stop }!
        if let row = dividerBelow, row < nearestBelow.stop {
            nearestBelow = (columns, row, true)
        }
        let bodyMaxY = nearestBelow.hitEdge
            ? max(bounds.maxY, CGFloat(nearestBelow.stop) - 0.1 * em)
            : min(CGFloat(pixels.height), CGFloat(nearestBelow.stop))

        // 只绕开障碍实际占的那几行：找到它的下沿，同一竖条再往下还有东西就接着找。
        for stripe in stripes where CGFloat(stripe.stop) < maxY {
            var top = stripe.stop
            while CGFloat(top) < maxY {
                let bottom = pixels.firstClearRow(from: top, limit: Int(maxY) - top, columns: stripe.columns, background: background, noise: noise)
                obstacles.append(CGRect(
                    x: CGFloat(stripe.columns.lowerBound) - sideMargin,
                    y: CGFloat(top) - edgeMargin,
                    width: CGFloat(stripe.columns.count) + 2 * sideMargin,
                    height: min(maxY, CGFloat(bottom) + edgeMargin) - (CGFloat(top) - edgeMargin)
                ))
                guard CGFloat(bottom) < maxY else { break }
                let next = pixels.scanRows(from: bottom + 2, step: 1, limit: Int(maxY) - bottom, columns: stripe.columns, background: background, noise: noise)
                guard CGFloat(next.stop) < maxY else { break }
                top = next.stop
            }
        }

        // 抹字的范围：各行墨迹外扩一点，盖住抗锯齿的边，但不越过旁边的东西——紧贴着的分隔线（上下连着的一整条），
        // 隔着一列干净背景之后才出现的颜色（字的抗锯齿是贴着笔画的），首行上面、末行下面量到的边。
        // 只削外扩的那一圈，墨迹带本身整条照抹：行距紧时相邻两行的墨迹带会叠在一起（各自扩进了对方），
        // 按两行的中线分开抹会削进上一行自己的字，它比下一行长出来的那一截就漏抹了。段落里相邻两行本来都要抹，不用互相让。
        let horizontalPad = 0.12 * em, verticalPad = max(1, 0.08 * em)
        let topLimit = aboveScan.hitEdge ? CGFloat(aboveScan.stop + 1) : 0
        let bottomLimit = nearestBelow.hitEdge ? CGFloat(nearestBelow.stop) : CGFloat(pixels.height)
        let eraseRects: [CGRect] = lines.indices.map { index in
            let line = lines[index]
            let rows = pixels.clampedRows(Int(line.minY)...max(Int(line.minY), Int(line.maxY) - 1))
            let probe = max(3, Int(0.35 * em))
            let above = Int(line.minY) - 2 - probe >= 0 ? (Int(line.minY) - 2 - probe)...(Int(line.minY) - 2) : nil
            let below = Int(line.maxY) + 1 + probe < pixels.height ? (Int(line.maxY) + 1)...(Int(line.maxY) + 1 + probe) : nil
            var maxX = line.maxX + horizontalPad, minX = line.minX - horizontalPad
            let rightZone = Array(Int(line.maxX)...Int(maxX.rounded(.up)))
            if let x = pixels.dividerColumn(in: rightZone, above: above, below: below, background: background, noise: noise)
                ?? pixels.separatedContentColumn(in: rightZone, rows: rows, background: background, noise: noise) {
                maxX = min(maxX, CGFloat(x))
            }
            let leftZone = Array((Int(minX.rounded(.down))...max(Int(minX.rounded(.down)), Int(line.minX) - 1)).reversed())
            if let x = pixels.dividerColumn(in: leftZone, above: above, below: below, background: background, noise: noise)
                ?? pixels.separatedContentColumn(in: leftZone, rows: rows, background: background, noise: noise) {
                minX = max(minX, CGFloat(x + 1))
            }
            let minY = index == 0 ? max(line.minY - verticalPad, topLimit) : line.minY - verticalPad
            let maxY = index == lines.count - 1 ? min(line.maxY + verticalPad, bottomLimit) : line.maxY + verticalPad
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY)).union(line)
        }

        return MeasuredStyle(
            lines: lines.map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) },
            fontSize: em / scale,
            textColor: ink,
            background: background,
            weight: weight,
            strokeRatio: strokeRatio,
            alignment: alignment,
            limits: .init(minX: minX / scale, maxX: maxX / scale, maxY: maxY / scale, minY: minY / scale, bodyMaxY: bodyMaxY / scale),
            obstacles: obstacles.map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) },
            eraseRects: eraseRects.map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) }
        )
    }

    /// 让系统字体排出来的墨迹正好是这个宽度的字号（pt）。字形随字号微调（SF 在 20pt 以上换成更紧凑的字形），
    /// 所以量两次。量出来和估算差得离谱（识别错字、漏字）时不信它，用估算值。
    static func fittedFontSize(of text: String, inkWidth: CGFloat, estimate: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        var size = estimate
        for _ in 0..<2 {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)])
            )
            let measured = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
            guard measured > 0 else { return estimate }
            size *= inkWidth / measured
        }
        return (0.7 * estimate...1.4 * estimate).contains(size) ? size : estimate
    }

    /// 用系统字体的常规字重，按同样的字号（pt）、同样的屏幕倍率和颜色把这行字画一遍，量出笔画宽度（像素）。
    static func regularStrokeWidth(
        of text: String,
        fontSize: CGFloat,
        scale: CGFloat,
        ink: PixelBuffer.RGB,
        background: PixelBuffer.RGB,
        colorSpace: CGColorSpace
    ) -> CGFloat? {
        let components: (PixelBuffer.RGB) -> [CGFloat] = { [CGFloat($0.r) / 255, CGFloat($0.g) / 255, CGFloat($0.b) / 255, 1] }
        guard let space = NSColorSpace(cgColorSpace: colorSpace),
              let backgroundColor = CGColor(colorSpace: colorSpace, components: components(background)) else { return nil }
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(colorSpace: space, components: components(ink), count: 4)
        ])
        let size = string.size()
        // 上下多留一些：后备字体（缅甸文、藏文）的字比 `size()` 给的行高高，别被位图切掉。
        let padding = ceil(1.0 * fontSize)
        let width = Int(ceil((size.width + 2 * padding) * scale)), height = Int(ceil((size.height + 2 * padding) * scale))
        guard size.width > 0, scale > 0, width < 16_000, height < 4_000,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: NSPoint(x: padding, y: padding))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(), let reference = PixelBuffer(image: image) else { return nil }
        let rect = CGRect(x: padding * scale, y: padding * scale, width: size.width * scale, height: size.height * scale)
        return reference.inkBand(in: rect, background: background, ink: ink, em: fontSize * scale).strokeWidth
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func spread(_ values: [CGFloat]) -> CGFloat {
        (values.max() ?? 0) - (values.min() ?? 0)
    }
}

/// 截图的 RGBA 像素（左上原点、逐行存放），外加量颜色、找墨迹、找空白、抹字用到的几个操作。
struct PixelBuffer {
    struct RGB: Equatable {
        var r: Int
        var g: Int
        var b: Int

        func distance(to other: RGB) -> Double {
            Double(squaredDistance(to: other)).squareRoot()
        }

        func squaredDistance(to other: RGB) -> Int {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return dr * dr + dg * dg + db * db
        }

        var luminance: Double { 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) }

        static func median(_ colors: [RGB]) -> RGB {
            guard !colors.isEmpty else { return RGB(r: 0, g: 0, b: 0) }
            func pick(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            return RGB(r: pick(colors.map(\.r)), g: pick(colors.map(\.g)), b: pick(colors.map(\.b)))
        }
    }

    /// 一行墨迹的上下边（像素行，bottom 不含），以及笔画宽度（墨迹横向连续的平均长度，量不出来为 nil）。
    struct InkBand {
        var top: CGFloat
        var bottom: CGFloat
        var strokeWidth: CGFloat?
    }

    let width: Int
    let height: Int
    /// 沿用截图自己的色彩空间（通常是显示器的），取出来的颜色画回去才不偏色。
    let colorSpace: CGColorSpace
    private(set) var bytes: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let candidates = [image.colorSpace].compactMap { $0 }.filter { $0.model == .rgb }
            + [CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        var usedSpace: CGColorSpace?
        for space in candidates {
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            if drawn {
                usedSpace = space
                break
            }
        }
        guard let usedSpace else { return nil }
        width = image.width
        height = image.height
        colorSpace = usedSpace
        bytes = buffer
    }

    func pixel(_ x: Int, _ y: Int) -> RGB {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let index = (cy * width + cx) * 4
        return RGB(r: Int(bytes[index]), g: Int(bytes[index + 1]), b: Int(bytes[index + 2]))
    }

    private mutating func setPixel(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let index = (y * width + x) * 4
        bytes[index] = UInt8(max(0, min(255, r.rounded())))
        bytes[index + 1] = UInt8(max(0, min(255, g.rounded())))
        bytes[index + 2] = UInt8(max(0, min(255, b.rounded())))
        bytes[index + 3] = 255
    }

    func color(_ rgb: RGB) -> NSColor {
        let components: [CGFloat] = [CGFloat(rgb.r) / 255, CGFloat(rgb.g) / 255, CGFloat(rgb.b) / 255, 1]
        if let space = NSColorSpace(cgColorSpace: colorSpace) {
            return NSColor(colorSpace: space, components: components, count: 4)
        }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }

    func clampedRows(_ rows: ClosedRange<Int>) -> ClosedRange<Int> {
        max(0, min(rows.lowerBound, height - 1))...max(0, min(rows.upperBound, height - 1))
    }

    func clampedColumns(_ columns: ClosedRange<Int>) -> ClosedRange<Int> {
        max(0, min(columns.lowerBound, width - 1))...max(0, min(columns.upperBound, width - 1))
    }

    /// 矩形外面一圈像素的中位色，也就是文字底下的背景色。文字像素只占少数，中位数不会被带偏。
    func ringMedian(around rect: CGRect, padding: CGFloat) -> RGB {
        let x0 = Int((rect.minX - padding).rounded(.down)), x1 = Int((rect.maxX + padding).rounded(.up))
        let y0 = Int((rect.minY - padding).rounded(.down)), y1 = Int((rect.maxY + padding).rounded(.up))
        var samples: [RGB] = []
        for x in stride(from: x0, through: x1, by: 2) {
            samples.append(pixel(x, y0))
            samples.append(pixel(x, y1))
        }
        for y in stride(from: y0, through: y1, by: 2) {
            samples.append(pixel(x0, y))
            samples.append(pixel(x1, y))
        }
        return RGB.median(samples)
    }

    /// 行框里和背景反差最大的那批像素的中位色，也就是文字颜色（抗锯齿的边缘不算）。
    func inkColor(in rect: CGRect, background: RGB) -> RGB {
        let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return background }
        var farthest = 0
        for y in y0...y1 {
            for x in x0...x1 {
                farthest = max(farthest, pixel(x, y).squaredDistance(to: background))
            }
        }
        guard farthest > 0 else { return background }
        let threshold = Int(Double(farthest) * 0.49)  // 距离的 0.7 倍
        var samples: [(distance: Int, color: RGB)] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let color = pixel(x, y)
                let distance = color.squaredDistance(to: background)
                if distance >= threshold { samples.append((distance, color)) }
            }
        }
        // 只取反差最大的那四分之一：1 倍屏上笔画才一个多像素，完全盖满的像素少，把七成覆盖的也算进来，
        // 中位色比真的字浅一截（近黑的字量成深灰），译文画浅了，量粗细时覆盖率也按浅色折算、量粗了。
        samples.sort { $0.distance > $1.distance }
        return RGB.median(samples.prefix(max(1, samples.count / 4)).map(\.color))
    }

    /// 这一行墨迹左右两端的位置（像素，maxX 不含）：在 `rect` 左右各放宽 `slack` 的范围里、
    /// `top..<bottom` 这几行中，找至少有两个墨迹像素的最左、最右一列。没有墨迹返回 nil。
    /// 紧贴着字的分隔线、按钮竖边颜色深的话也过得了墨迹阈值，但它在字的上方和下方都连着（同 `dividerColumn`），
    /// 字的笔画不会伸到字外面——这样的列不算字。算进来的话它会被当成字抹掉，往外扫也从它外面开始、让译文越过它，
    /// 字号也按多出来的宽度量偏。
    func inkExtent(in rect: CGRect, top: CGFloat, bottom: CGFloat, background: RGB, ink: RGB, slack: CGFloat, em: CGFloat) -> (minX: CGFloat, maxX: CGFloat)? {
        let contrast = ink.distance(to: background)
        guard contrast > 20 else { return nil }
        let threshold = Int(pow(max(20, 0.45 * contrast), 2))
        let x0 = max(0, Int(rect.minX - slack)), x1 = min(width - 1, Int((rect.maxX + slack).rounded(.up)) - 1)
        let y0 = max(0, Int(top)), y1 = min(height - 1, Int(bottom) - 1)
        guard x1 >= x0, y1 >= y0 else { return nil }
        func hasInk(_ x: Int) -> Bool {
            var hits = 0
            for y in y0...y1 where pixel(x, y).squaredDistance(to: background) >= threshold {
                hits += 1
                if hits >= 2 { return true }
            }
            return false
        }
        let probe = max(3, Int(0.35 * em))
        let above = y0 - 2 - probe >= 0 ? (y0 - 2 - probe)...(y0 - 2) : nil
        let below = y1 + 2 + probe < height ? (y1 + 2)...(y1 + 2 + probe) : nil
        func isDivider(_ x: Int) -> Bool {
            guard let above, let below else { return false }
            func continuous(_ rows: ClosedRange<Int>) -> Bool {
                rows.filter { pixel(x, $0).squaredDistance(to: background) >= threshold }.count * 4 >= rows.count * 3
            }
            return continuous(above) && continuous(below)
        }
        func isText(_ x: Int) -> Bool { hasInk(x) && !isDivider(x) }
        guard let left = (x0...x1).first(where: isText),
              let right = (x0...x1).reversed().first(where: isText) else { return nil }
        return (CGFloat(left), CGFloat(right + 1))
    }

    /// 这一行墨迹的上下边和笔画宽度。从行框中心往上下扩，碰到空行就停：
    /// Vision 的行框有时会伸进相邻的行，不能直接拿来当抹字的范围。
    func inkBand(in rect: CGRect, background: RGB, ink: RGB, em: CGFloat) -> InkBand {
        let fallback = InkBand(top: rect.minY, bottom: rect.maxY, strokeWidth: nil)
        let contrast = ink.distance(to: background)
        guard contrast > 20 else { return fallback }
        let threshold = Int(pow(max(20, 0.45 * contrast), 2))

        let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX.rounded(.up)) - 1)
        let center = rect.midY
        let searchTop = max(0, Int(max(rect.minY - 0.35 * em, center - 0.75 * em)))
        let searchBottom = min(height - 1, Int(min(rect.maxY + 0.35 * em, center + 0.75 * em)))
        guard x1 >= x0, searchBottom > searchTop else { return fallback }

        // 「整行同色」要看得比文字框宽：左右各放宽一个字宽，几乎整行都是墨迹色的才是和字同色的一整块
        // （白字按钮外面的白底，一整片）；字的笔画不会伸到字外面，「工」「王」的一横占满文字框也照样算字。
        // 字框外面取不到半个字宽（选区紧紧框着字，放宽的部分被截图边缘截掉了）就不判：剩下的差不多全是字，一横就能占满；
        // 取得到半个字宽，一横（最多一个字宽）最多占三分之二，到不了。
        let wideX0 = max(0, Int(rect.minX - em)), wideX1 = min(width - 1, Int(rect.maxX + em))
        let outside = (x0 - wideX0) + (wideX1 - x1)
        let judgesSolid = Double(outside) >= max(3, 0.5 * Double(em))
        // 笔画宽度按覆盖率算：一段笔画的宽度 = 段里各像素的覆盖率之和，加上两边各一个抗锯齿像素的覆盖率。
        // 1 倍屏上一笔竖画只有一个多像素，按「过阈值的像素个数」数，落在像素格的不同位置会数成 1 个或 2 个，
        // 宽度差出三成，常规体和半粗体就分不开；覆盖率加起来不管落在哪都一样。最后取各段的中位数：
        // 横画、弧线的顶和底在一行里是长长的一段，平均会被它们拉偏，中位数量的是竖画。
        let inkR = Double(ink.r - background.r), inkG = Double(ink.g - background.g), inkB = Double(ink.b - background.b)
        let inkNorm = inkR * inkR + inkG * inkG + inkB * inkB
        func coverage(_ x: Int, _ y: Int) -> Double {
            guard x >= 0, x < width else { return 0 }
            let p = pixel(x, y)
            return min(1, max(0, (Double(p.r - background.r) * inkR + Double(p.g - background.g) * inkG + Double(p.b - background.b) * inkB) / inkNorm))
        }
        var counts: [Int] = []
        var strokeRuns: [[Double]] = []
        var solidRows: [Bool] = []
        for y in searchTop...searchBottom {
            var count = 0, inside = false, current = 0.0
            var rowRuns: [Double] = []
            for x in x0...x1 {
                let isInk = pixel(x, y).squaredDistance(to: background) >= threshold
                if isInk {
                    count += 1
                    if !inside { current = coverage(x - 1, y) }
                    current += coverage(x, y)
                } else if inside {
                    rowRuns.append(current + coverage(x, y))
                }
                inside = isInk
            }
            if inside { rowRuns.append(current + coverage(x1 + 1, y)) }
            strokeRuns.append(rowRuns)
            var wide = count
            for x in wideX0..<x0 where pixel(x, y).squaredDistance(to: background) >= threshold { wide += 1 }
            if x1 < wideX1 {
                for x in (x1 + 1)...wideX1 where pixel(x, y).squaredDistance(to: background) >= threshold { wide += 1 }
            }
            counts.append(count)
            solidRows.append(judgesSolid && Double(wide) >= 0.85 * Double(wideX1 - wideX0 + 1))
        }
        let minimum = max(1, (x1 - x0) / 250)
        // 碰到和字同色的一整块就停，不然矮按钮上的白字，墨迹带会一直伸到按钮外面，字宽、字号跟着量错。
        func isInk(_ row: Int) -> Bool { counts[row] >= minimum && !solidRows[row] }
        let centerRow = Int(center) - searchTop
        guard let start = counts.indices
            .filter(isInk)
            .min(by: { abs($0 - centerRow) < abs($1 - centerRow) }) else {
            return fallback
        }

        // 中间隔着几行空白也接着往外扩（i 的点、声调、泰文缅甸文的元音符号、下划线），但隔着空白又碰到墨迹时先看一眼：
        // 从那里往外连着高过 0.45 个字宽的，是行距紧的上一行或下一行字（可能根本不在这一段里），停在空白这边——
        // 扩进去的话墨迹带就盖住了别人的字，抹字会连它一起抹掉。往外看可以超出搜索范围。
        let maxGap = max(2, Int(0.2 * em))
        let lineRun = max(3, Int(0.45 * em))
        func rowHasInk(_ y: Int) -> Bool {
            guard y >= 0, y < height else { return false }
            var count = 0
            for x in x0...x1 where pixel(x, y).squaredDistance(to: background) >= threshold {
                count += 1
                if count >= minimum { return true }
            }
            return false
        }
        func isAnotherLine(from row: Int, step: Int) -> Bool {
            (0..<lineRun).allSatisfy { rowHasInk(searchTop + row + $0 * step) }
        }
        // 空白超过 0.2 个字宽就停——还在识别出的这一行的框里就接着找：「二」「三」的几横之间隔得远，但都是这一个字的。
        // 框伸进了相邻的行也不怕，那一行连成一大片的字身照样被上面「另一行字」的检查挡住。
        let boxTop = Int(rect.minY) - searchTop, boxBottom = Int(rect.maxY.rounded(.up)) - 1 - searchTop
        var top = start, bottom = start, gap = 0
        var row = start - 1
        while row >= 0, !solidRows[row] {
            if isInk(row) {
                if gap > 0, isAnotherLine(from: row, step: -1) { break }
                top = row
                gap = 0
            } else {
                gap += 1
                if gap > maxGap, row < boxTop { break }
            }
            row -= 1
        }
        gap = 0
        row = start + 1
        while row < counts.count, !solidRows[row] {
            if isInk(row) {
                if gap > 0, isAnotherLine(from: row, step: 1) { break }
                bottom = row
                gap = 0
            } else {
                gap += 1
                if gap > maxGap, row > boxBottom { break }
            }
            row += 1
        }

        let widths = strokeRuns[top...bottom].flatMap { $0 }.sorted()
        return InkBand(
            top: CGFloat(searchTop + top),
            bottom: CGFloat(searchTop + bottom + 1),
            strokeWidth: widths.isEmpty ? nil : CGFloat(widths[widths.count / 2])
        )
    }

    /// 矩形外面一圈像素的亮度噪点（稳健的标准差：中位绝对偏差 × 1.4826）。界面截图的纯色背景接近 0。
    func ringNoise(around rect: CGRect, padding: CGFloat, median: RGB) -> Double {
        let x0 = Int((rect.minX - padding).rounded(.down)), x1 = Int((rect.maxX + padding).rounded(.up))
        let y0 = Int((rect.minY - padding).rounded(.down)), y1 = Int((rect.maxY + padding).rounded(.up))
        let center = median.luminance
        var deviations: [Double] = []
        for x in stride(from: x0, through: x1, by: 2) {
            deviations.append(abs(pixel(x, y0).luminance - center))
            deviations.append(abs(pixel(x, y1).luminance - center))
        }
        for y in stride(from: y0, through: y1, by: 2) {
            deviations.append(abs(pixel(x0, y).luminance - center))
            deviations.append(abs(pixel(x1, y).luminance - center))
        }
        guard !deviations.isEmpty else { return 0 }
        deviations.sort()
        return 1.4826 * deviations[deviations.count / 2]
    }

    /// 一列一列地往外扫（`step` 为 1 往右、-1 往左，`rows` 是要看的行），找第一处「有东西」的地方：
    /// - 突变：这一列和两列之前比，有几个像素明显变了色——文字、图标、分隔线、色块的边，`hitEdge` 为 true；
    /// - 走远了：和起点的背景差得太多——渐变走远了、慢慢换了底色，`hitEdge` 为 false。
    /// 阈值按背景本身的噪点放大，照片、颗粒背景上的噪点不算东西；突变要有三个像素，免得噪点误判；
    /// 走远了只要两个像素，一两个像素宽的分隔线也拦得住。
    /// - 细线：1 倍屏上一个像素粗、顺着扫的方向走的线（标题后面的横线、连接线），每一列只有一个像素变色，
    ///   上面两条都凑不够数；同一行上一连三列都变了色就是它，停在它开头那一列，`hitEdge` 为 true。
    /// 扫出 `limit` 个像素或者扫到图片外（`width` 或 -1）都没碰到，返回停下的地方，`hitEdge` 为 false。
    func scanColumns(from start: Int, step: Int, limit: Int, rows: ClosedRange<Int>, background: RGB, noise: Double) -> (stop: Int, hitEdge: Bool) {
        let edge = Int(pow(max(12, 4.5 * noise), 2))
        let drift = Int(pow(max(40, 5 * noise), 2))
        var runs = [Int](repeating: 0, count: rows.count)
        var x = min(max(start, -1), width)
        let end = start + step * max(1, limit)
        while x >= 0, x < width, x != end {
            var edges = 0, drifts = 0
            for (index, y) in rows.enumerated() {
                let color = pixel(x, y)
                if color.squaredDistance(to: pixel(x - 2 * step, y)) > edge { edges += 1 }
                if color.squaredDistance(to: background) > drift {
                    drifts += 1
                    runs[index] += 1
                } else {
                    runs[index] = 0
                }
            }
            if edges >= 3 { return (x, true) }
            if drifts >= 2 { return (x, false) }
            if runs.contains(where: { $0 >= 3 }) { return (x - 2 * step, true) }
            x += step
        }
        return (x, false)
    }

    /// 扫描跳过的那一小段留白（墨迹和扫描起点之间）里，有没有紧挨着字的分隔线。分隔线是一整条，在字的上方和下方
    /// （`above`/`below`，不含贴着字的那一两行）都连着；字自己的抗锯齿只贴在笔画边上，不会伸到字外面。
    /// `candidates` 按离字由近到远排，返回最近的那一列。
    func dividerColumn(in candidates: [Int], above: ClosedRange<Int>?, below: ClosedRange<Int>?, background: RGB, noise: Double) -> Int? {
        let differs = Int(pow(max(12, 4.5 * noise), 2))
        func continuous(_ x: Int, _ rows: ClosedRange<Int>?) -> Bool {
            guard let rows else { return false }
            let hits = rows.filter { pixel(x, $0).squaredDistance(to: background) > differs }.count
            return hits * 4 >= rows.count * 3
        }
        return candidates.first { continuous($0, above) && continuous($0, below) }
    }

    /// 从墨迹边上往外（`candidates` 按由近到远排），先碰到一列干净的背景、再碰到有颜色的列——那是别的东西，
    /// 不是字的抗锯齿（抗锯齿贴着笔画，中间不会隔着干净的背景）。返回那一列。
    func separatedContentColumn(in candidates: [Int], rows: ClosedRange<Int>, background: RGB, noise: Double) -> Int? {
        let differs = Int(pow(max(12, 4.5 * noise), 2))
        var sawClean = false
        for x in candidates where x >= 0 && x < width {
            let hits = rows.filter { pixel(x, $0).squaredDistance(to: background) > differs }.count
            if hits <= rows.count / 20 {
                sawClean = true
            } else if sawClean {
                return x
            }
        }
        return nil
    }

    /// 同 `dividerColumn`，横着的分隔线：在字的左边和右边都连着。
    func dividerRow(in candidates: [Int], left: ClosedRange<Int>?, right: ClosedRange<Int>?, background: RGB, noise: Double) -> Int? {
        let differs = Int(pow(max(12, 4.5 * noise), 2))
        func continuous(_ y: Int, _ columns: ClosedRange<Int>?) -> Bool {
            guard let columns else { return false }
            let hits = columns.filter { pixel($0, y).squaredDistance(to: background) > differs }.count
            return hits * 4 >= columns.count * 3
        }
        return candidates.first { continuous($0, left) && continuous($0, right) }
    }

    /// 从第 `start` 行往下，找第一处连续三行都「没东西」（按 `scanRows` 的标准）的地方，也就是障碍的下沿。
    /// 扫出 `limit` 行还没有，返回 `start + limit`。
    func firstClearRow(from start: Int, limit: Int, columns: ClosedRange<Int>, background: RGB, noise: Double) -> Int {
        let edge = Int(pow(max(12, 4.5 * noise), 2))
        let drift = Int(pow(max(40, 5 * noise), 2))
        let end = min(height, start + max(1, limit))
        var clearRows = 0
        var y = max(0, start)
        while y < end {
            var edges = 0, drifts = 0
            for x in columns {
                let color = pixel(x, y)
                if color.squaredDistance(to: pixel(x, y - 2)) > edge { edges += 1 }
                if color.squaredDistance(to: background) > drift { drifts += 1 }
            }
            clearRows = edges < 3 && drifts < 2 ? clearRows + 1 : 0
            if clearRows >= 3 { return y - 2 }
            y += 1
        }
        return start + max(1, limit)
    }

    /// 同 `scanColumns`，一行一行地扫（细线是竖着的：同一列上一连三行都变了色）。
    func scanRows(from start: Int, step: Int, limit: Int, columns: ClosedRange<Int>, background: RGB, noise: Double) -> (stop: Int, hitEdge: Bool) {
        let edge = Int(pow(max(12, 4.5 * noise), 2))
        let drift = Int(pow(max(40, 5 * noise), 2))
        var runs = [Int](repeating: 0, count: columns.count)
        var y = min(max(start, -1), height)
        let end = start + step * max(1, limit)
        while y >= 0, y < height, y != end {
            var edges = 0, drifts = 0
            for (index, x) in columns.enumerated() {
                let color = pixel(x, y)
                if color.squaredDistance(to: pixel(x, y - 2 * step)) > edge { edges += 1 }
                if color.squaredDistance(to: background) > drift {
                    drifts += 1
                    runs[index] += 1
                } else {
                    runs[index] = 0
                }
            }
            if edges >= 3 { return (y, true) }
            if drifts >= 2 { return (y, false) }
            if runs.contains(where: { $0 >= 3 }) { return (y - 2 * step, true) }
            y += step
        }
        return (y, false)
    }

    /// 抹掉一块：用四周一圈像素拟合一个平面（纯色、线性渐变都能还原），拟合时剔除离群的像素，
    /// 免得挨着的图标、别的字把颜色带偏。背景有颗粒感时补上同样强度的噪点，免得抹过的地方比周围「干净」一块。
    /// 四周一圈都在图片外面时（整张图就是这一块）用 `fallback` 的颜色。
    mutating func erase(_ rect: CGRect, fallback: RGB) {
        let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width - 1, Int(rect.maxX.rounded(.up)) - 1)
        let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height - 1, Int(rect.maxY.rounded(.up)) - 1)
        guard x1 >= x0, y1 >= y0 else { return }

        let band = 3
        let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
        let sx = Double(x1 - x0) / 2 + Double(band), sy = Double(y1 - y0) / 2 + Double(band)
        var samples: [Sample] = []
        let step = max(1, (x1 - x0 + y1 - y0) / 600)
        func add(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            samples.append(Sample(u: (Double(x) - cx) / sx, v: (Double(y) - cy) / sy, color: pixel(x, y)))
        }
        for distance in 1...band {
            for x in stride(from: x0 - band, through: x1 + band, by: step) {
                add(x, y0 - distance)
                add(x, y1 + distance)
            }
            for y in stride(from: y0, through: y1, by: step) {
                add(x0 - distance, y)
                add(x1 + distance, y)
            }
        }

        var plane = Plane.constant(fallback)
        // 颗粒：四周一圈（去掉离群的）相对平面的亮度残差，抹字时随机抽来加上，强度和分布都跟四周一样。
        var grain: [Double] = []
        if samples.count >= 8 {
            var inliers = samples
            for _ in 0..<3 {
                guard let fitted = Plane.fit(inliers) else { break }
                plane = fitted
                let residuals = samples.map { plane.residual(of: $0) }
                let sortedResiduals = residuals.sorted()
                let cutoff = max(8, 2.5 * sortedResiduals[sortedResiduals.count / 2])
                let next = zip(samples, residuals).filter { $0.1 <= cutoff }.map(\.0)
                guard next.count >= 8 else { break }
                inliers = next
            }
            let residuals = samples.map { sample -> Double in
                let (r, g, b) = plane.value(u: sample.u, v: sample.v)
                return sample.color.luminance - (0.299 * r + 0.587 * g + 0.114 * b)
            }
            let spread = 1.4826 * residuals.map(abs).sorted()[residuals.count / 2]
            if spread > 2 {
                grain = residuals.filter { abs($0) <= max(8, 3 * spread) }
            }
        }

        var seed = UInt64(truncatingIfNeeded: (x0 &* 73_856_093) ^ (y0 &* 19_349_663)) | 1
        for y in y0...y1 {
            let v = (Double(y) - cy) / sy
            for x in x0...x1 {
                var (r, g, b) = plane.value(u: (Double(x) - cx) / sx, v: v)
                if !grain.isEmpty {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let noise = grain[Int((seed >> 33) % UInt64(grain.count))]
                    r += noise
                    g += noise
                    b += noise
                }
                setPixel(x, y, r, g, b)
            }
        }
    }

    private struct Sample {
        let u: Double
        let v: Double
        let color: RGB
    }

    /// 每个颜色通道一个平面：值 = a + b·u + c·v（u、v 是归一化到 ±1 左右的坐标）。
    private struct Plane {
        var red: (a: Double, b: Double, c: Double)
        var green: (a: Double, b: Double, c: Double)
        var blue: (a: Double, b: Double, c: Double)

        static func constant(_ color: RGB) -> Plane {
            Plane(red: (Double(color.r), 0, 0), green: (Double(color.g), 0, 0), blue: (Double(color.b), 0, 0))
        }

        func value(u: Double, v: Double) -> (Double, Double, Double) {
            (red.a + red.b * u + red.c * v, green.a + green.b * u + green.c * v, blue.a + blue.b * u + blue.c * v)
        }

        func residual(of sample: Sample) -> Double {
            let (r, g, b) = value(u: sample.u, v: sample.v)
            let dr = Double(sample.color.r) - r, dg = Double(sample.color.g) - g, db = Double(sample.color.b) - b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }

        /// 最小二乘。样本只落在一条线上（解不出斜率）时退回常数。
        static func fit(_ samples: [Sample]) -> Plane? {
            guard !samples.isEmpty else { return nil }
            var n = 0.0, su = 0.0, sv = 0.0, suu = 0.0, svv = 0.0, suv = 0.0
            var r = (0.0, 0.0, 0.0), g = (0.0, 0.0, 0.0), b = (0.0, 0.0, 0.0)
            for sample in samples {
                let u = sample.u, v = sample.v
                n += 1
                su += u
                sv += v
                suu += u * u
                svv += v * v
                suv += u * v
                let cr = Double(sample.color.r), cg = Double(sample.color.g), cb = Double(sample.color.b)
                r.0 += cr; r.1 += u * cr; r.2 += v * cr
                g.0 += cg; g.1 += u * cg; g.2 += v * cg
                b.0 += cb; b.1 += u * cb; b.2 += v * cb
            }
            // [n su sv; su suu suv; sv suv svv] · [a b c]ᵀ = [Σc Σu·c Σv·c]ᵀ，按克拉默法则解。
            func det(_ m00: Double, _ m01: Double, _ m02: Double,
                     _ m10: Double, _ m11: Double, _ m12: Double,
                     _ m20: Double, _ m21: Double, _ m22: Double) -> Double {
                m00 * (m11 * m22 - m12 * m21) - m01 * (m10 * m22 - m12 * m20) + m02 * (m10 * m21 - m11 * m20)
            }
            let d = det(n, su, sv, su, suu, suv, sv, suv, svv)
            guard abs(d) > 1e-6 * max(1, n * n * n) else {
                return Plane(red: (r.0 / n, 0, 0), green: (g.0 / n, 0, 0), blue: (b.0 / n, 0, 0))
            }
            func solve(_ s: (Double, Double, Double)) -> (a: Double, b: Double, c: Double) {
                (det(s.0, su, sv, s.1, suu, suv, s.2, suv, svv) / d,
                 det(n, s.0, sv, su, s.1, suv, sv, s.2, svv) / d,
                 det(n, su, s.0, su, suu, s.1, sv, suv, s.2) / d)
            }
            return Plane(red: solve(r), green: solve(g), blue: solve(b))
        }
    }

    /// 把像素（连同 `draw` 里画的东西）做成图片。`draw` 在左上原点、以 pt 为单位的坐标系里画。
    func makeImage(scale: CGFloat, draw: () -> Void) -> CGImage? {
        var buffer = bytes
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()
        }
    }
}
