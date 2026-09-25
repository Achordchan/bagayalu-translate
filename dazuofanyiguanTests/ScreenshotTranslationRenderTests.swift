//
//  ScreenshotTranslationRenderTests.swift
//  dazuofanyiguanTests
//
//  截图翻译的回贴：排版规则，以及用真实 Vision 跑的端到端检查——回贴后的图再识别一遍，
//  原文没了、译文在原位，字号、颜色、粗细和原文一致，没翻的地方一个像素都不动。
//

import AppKit
import Testing
@testable import 大佐翻译官v1

@Suite("截图翻译：回贴排版")
struct ScreenshotTranslationLayoutTests {
    /// 假的量字：每个字 0.6 个字号宽，行高 1.2 个字号；给了宽度就按宽度折行。
    private let measure: ScreenshotTranslationLayout.Measure = { text, fontSize, _, width, lineHeight, _ in
        let natural = CGFloat(text.count) * 0.6 * fontSize
        let line = lineHeight ?? 1.2 * fontSize
        // 墨迹占行框中间的 70%。
        let ink = (top: 0.15 * line, bottom: 0.85 * line)
        guard let width else { return .init(size: CGSize(width: natural, height: line), inkTop: ink.top, inkBottom: ink.bottom) }
        let lines = max(1, Int((natural / width).rounded(.up)))
        return .init(size: CGSize(width: min(natural, width), height: CGFloat(lines) * line), inkTop: ink.top, inkBottom: ink.bottom)
    }

    private func block(
        _ text: String,
        lines: [CGRect],
        size: CGFloat = 14,
        alignment: NSTextAlignment = .left,
        limits: ScreenshotTranslationLayout.Limits
    ) -> ScreenshotTranslationLayout.Block {
        .init(id: UUID(), text: text, lines: lines, fontSize: size, weight: .regular, alignment: alignment, limits: limits)
    }

    private func place(_ block: ScreenshotTranslationLayout.Block) throws -> ScreenshotTranslationLayout.Placement {
        try #require(ScreenshotTranslationLayout.plan([block], canvas: CGSize(width: 400, height: 300), measure: measure).first)
    }

    @Test func closeFontSizesAreHarmonized() {
        #expect(ScreenshotTranslationLayout.harmonizedFontSizes([13, 13.4, 12.8, 22, 21.5, 11]) == [13, 13, 13, 22, 22, 11])
    }

    @Test func shortTranslationKeepsTheOriginalSizeAndPosition() throws {
        let line = CGRect(x: 20, y: 10, width: 100, height: 14)
        let placement = try place(block("十个字的译文十个字", lines: [line], limits: .init(minX: 0, maxX: 300, maxY: 200)))
        #expect(placement.fontSize == 14)
        #expect(placement.frame.minX == 20)
        #expect(abs(placement.frame.midY - line.midY) < 0.01)
        #expect(placement.lineHeight == nil)
    }

    @Test func longSingleLineExtendsIntoTheFreeSpaceThenShrinksALittle() throws {
        // 能延伸到 x = 120（宽 100），13 个字在 14pt 要 109.2，缩到 90% 放得下。
        let line = CGRect(x: 20, y: 10, width: 60, height: 14)
        let placement = try place(block("一二三四五六七八九十一二三", lines: [line], limits: .init(minX: 0, maxX: 120, maxY: 26)))
        #expect(placement.fontSize < 14)
        #expect(placement.fontSize >= 14 * 0.82)
        #expect(placement.frame.maxX <= 121)
    }

    @Test func singleLineWrapsDownWhenThereIsRoomBelow() throws {
        let line = CGRect(x: 20, y: 10, width: 60, height: 14)
        let text = String(repeating: "字", count: 20)
        let placement = try place(block(text, lines: [line], limits: .init(minX: 0, maxX: 120, maxY: 200)))
        #expect(placement.fontSize == 14)
        #expect(placement.frame.height > 2 * 14)
        #expect(placement.frame.width == 100)
    }

    @Test func centeredSingleLineGrowsSymmetrically() throws {
        let line = CGRect(x: 100, y: 10, width: 40, height: 14)
        let placement = try place(block("升级到专业版本", lines: [line], alignment: .center, limits: .init(minX: 60, maxX: 180, maxY: 26)))
        #expect(abs(placement.frame.midX - line.midX) < 0.01)
        #expect(placement.frame.minX >= 60)
        #expect(placement.frame.maxX <= 180)
    }

    @Test func paragraphReflowsWithinTheOriginalWidthAndLinePitch() throws {
        let lines = (0..<3).map { CGRect(x: 20, y: 10 + CGFloat($0) * 22, width: 200, height: 14) }
        let placement = try place(block(String(repeating: "字", count: 30), lines: lines, limits: .init(minX: 20, maxX: 220, maxY: 200)))
        #expect(placement.fontSize == 14)
        #expect(placement.frame.width == 200)
        #expect(placement.lineHeight == 22)
        #expect(placement.eraseRects.count == 3)
        for (erase, line) in zip(placement.eraseRects, lines) {
            #expect(erase.contains(line))
        }
    }

    /// 审核第一轮（#12）：两段各自量出来的空白可能是同一块。并排的两个居中标签都往中间长，排完不能叠在一起。
    @Test func neighboursDoNotClaimTheSameGap() throws {
        let a = block("第一个标签很长很长的译文", lines: [CGRect(x: 100, y: 10, width: 40, height: 14)], alignment: .center, limits: .init(minX: 60, maxX: 196, maxY: 26))
        let b = block("第二个标签很长很长的译文", lines: [CGRect(x: 200, y: 10, width: 40, height: 14)], alignment: .center, limits: .init(minX: 144, maxX: 280, maxY: 26))
        let unresolved = [a, b].map { try? place($0) }
        #expect(unresolved[0]!.frame.intersects(unresolved[1]!.frame), "这组数据本来就会撞，才测得出来")

        let placements = ScreenshotTranslationLayout.plan([a, b], canvas: CGSize(width: 400, height: 300), measure: measure)
        #expect(placements.count == 2)
        #expect(!placements[0].frame.intersects(placements[1].frame))
        // 从两段原文正中间（x = 170）劈开。
        #expect(placements[0].frame.maxX <= 170)
        #expect(placements[1].frame.minX >= 170)
        #expect(abs(placements[0].frame.midX - 120) < 0.01)
        #expect(abs(placements[1].frame.midX - 220) < 0.01)
    }

    @Test func textGrowingDownStopsAboveTheTranslationBelow() throws {
        // 上面一段折行往下长（限制给得很宽），下面一段的译文往右长到它下面。
        let upper = block(String(repeating: "字", count: 100), lines: [CGRect(x: 20, y: 10, width: 180, height: 14)], limits: .init(minX: 20, maxX: 200, maxY: 200))
        let lower = block("往右边长的一段比较长的译文", lines: [CGRect(x: 50, y: 70, width: 50, height: 14)], limits: .init(minX: 50, maxX: 380, maxY: 90))
        let unresolved = [upper, lower].map { try? place($0) }
        #expect(unresolved[0]!.frame.intersects(unresolved[1]!.frame), "这组数据本来就会撞，才测得出来")

        let placements = ScreenshotTranslationLayout.plan([upper, lower], canvas: CGSize(width: 400, height: 300), measure: measure)
        #expect(placements.count == 2)
        #expect(placements[0].frame.maxY <= placements[1].frame.minY)
    }

    /// 审核第二轮（#12）：原文比 8pt 还小时，缩小的下限不能反过来把字放大。
    @Test func tinyTextIsNeverEnlarged() throws {
        let line = CGRect(x: 20, y: 10, width: 60, height: 6)
        let fits = try place(block("小字", lines: [line], size: 6, limits: .init(minX: 0, maxX: 300, maxY: 20)))
        #expect(fits.fontSize == 6)
        let tooLong = try place(block(String(repeating: "字", count: 80), lines: [line], size: 6, limits: .init(minX: 0, maxX: 90, maxY: 14)))
        #expect(tooLong.fontSize == 6)
        #expect(tooLong.maximumLines == 1)
        let paragraph = try place(block(String(repeating: "字", count: 200), lines: [line, line.offsetBy(dx: 0, dy: 8)], size: 6, limits: .init(minX: 20, maxX: 80, maxY: 30)))
        #expect(paragraph.fontSize == 6)
    }

    /// 审核第二轮（#12）：段落外框里、短行旁边的东西要绕开。用真实的 TextKit 排，逐行查有没有压到它。
    @Test func paragraphFlowsAroundAnObstacleInsideItsBounds() throws {
        let lines = [CGRect(x: 20, y: 10, width: 300, height: 14), CGRect(x: 20, y: 32, width: 80, height: 14)]
        let icon = CGRect(x: 140, y: 28, width: 180, height: 22)
        var paragraph = block(String(repeating: "很长的译文", count: 12), lines: lines, limits: .init(minX: 20, maxX: 320, maxY: 200))
        paragraph.obstacles = [icon]
        let placement = try #require(ScreenshotTranslationLayout.plan([paragraph], canvas: CGSize(width: 400, height: 300)).first)
        #expect(placement.exclusions.count == 1)
        let string = ScreenshotTranslationLayout.attributedString(
            placement.text, fontSize: placement.fontSize, weight: placement.weight, color: .black,
            alignment: placement.alignment, lineHeight: placement.lineHeight
        )
        let layout = ScreenshotTranslationLayout.TextLayout(string, size: placement.frame.size, exclusions: placement.exclusions, maximumLines: placement.maximumLines)
        let drawn = layout.lineRects.map { $0.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY) }
        #expect(drawn.count >= 3)
        for rect in drawn {
            #expect(!rect.insetBy(dx: 0, dy: 0.12 * placement.fontSize).intersects(icon), "\(rect) 压到了 \(icon)")
        }
    }

    /// 审核第三轮（#12）：标签落在段落外框里（短行旁边），两段外框叠在一起、从中间劈不开；
    /// 两段都译长时，段落要绕开标签的译文排。用真实的 TextKit 排，逐行查。
    @Test func paragraphFlowsAroundATranslatedLabelInsideItsBounds() throws {
        let label = CGRect(x: 140, y: 32, width: 40, height: 14)
        var paragraph = block(String(repeating: "很长的译文", count: 12), lines: [
            CGRect(x: 20, y: 10, width: 300, height: 14), CGRect(x: 20, y: 32, width: 80, height: 14)
        ], limits: .init(minX: 20, maxX: 320, maxY: 200))
        // 渲染器量出来的：段落绕开标签原文所在的地方。
        paragraph.obstacles = [label.insetBy(dx: -4, dy: -1.4)]
        let guest = block("查看这项订阅的详细信息", lines: [label], limits: .init(minX: 104, maxX: 380, maxY: 200))

        func lineRects(_ placement: ScreenshotTranslationLayout.Placement) -> [CGRect] {
            let string = ScreenshotTranslationLayout.attributedString(
                placement.text, fontSize: placement.fontSize, weight: placement.weight, color: .black,
                alignment: placement.alignment, lineHeight: placement.lineHeight
            )
            return ScreenshotTranslationLayout.TextLayout(string, size: placement.frame.size, exclusions: placement.exclusions, maximumLines: placement.maximumLines)
                .lineRects.map { $0.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY) }
        }
        func overlaps(_ host: ScreenshotTranslationLayout.Placement, _ guest: ScreenshotTranslationLayout.Placement) -> Bool {
            lineRects(host).contains { $0.insetBy(dx: 0, dy: 0.12 * host.fontSize).intersects(guest.frame.insetBy(dx: 0, dy: 0.12 * guest.fontSize)) }
        }

        let canvas = CGSize(width: 400, height: 300)
        let alone = [paragraph, guest].compactMap { ScreenshotTranslationLayout.plan([$0], canvas: canvas).first }
        #expect(overlaps(alone[0], alone[1]), "这组数据各排各的本来就会撞，才测得出来")

        let placements = ScreenshotTranslationLayout.plan([paragraph, guest], canvas: canvas)
        #expect(placements.count == 2)
        #expect(!overlaps(placements[0], placements[1]))
    }

    /// 审核第三轮（#12）：单行的行框按译文本身、按 TextKit 实际排出来的量。缅甸文用后备字体，一行 31pt，
    /// 系统字体（和 `NSAttributedString.size()`）只有 17pt；按那个定行框，字溢出、竖直位置偏下。
    @Test func singleLineFrameFitsTheTranslationsOwnLineHeight() throws {
        let burmese = "မြန်မာစာ ဘာသာပြန်"
        let line = CGRect(x: 20, y: 30, width: 200, height: 14)
        let placement = try #require(ScreenshotTranslationLayout.plan(
            [block(burmese, lines: [line], limits: .init(minX: 0, maxX: 380, maxY: 80))],
            canvas: CGSize(width: 400, height: 300)
        ).first)
        let string = ScreenshotTranslationLayout.attributedString(
            placement.text, fontSize: placement.fontSize, weight: placement.weight, color: .black,
            alignment: placement.alignment, lineHeight: placement.lineHeight
        )
        let layout = ScreenshotTranslationLayout.TextLayout(string, size: placement.frame.size, maximumLines: placement.maximumLines)
        let actual = try #require(layout.lineRects.first)
        #expect(actual.height > string.size().height + 4, "这组数据要是后备字体更高的文字，才测得出来")
        #expect(placement.frame.height >= actual.height - 0.5)
        #expect(abs(placement.frame.minY + actual.midY - line.midY) < 1, "译文这一行没有居中在原文那一行上")
        #expect(layout.laysOutEverything)
    }

    /// 把排好的一段画到白底位图上（2 倍），返回有墨迹的像素行的上下范围（pt）。
    private func inkRows(of placement: ScreenshotTranslationLayout.Placement, canvas: CGSize) -> ClosedRange<CGFloat>? {
        let context = CGContext(
            data: nil, width: Int(canvas.width * 2), height: Int(canvas.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvas.width * 2, height: canvas.height * 2))
        context.translateBy(x: 0, y: canvas.height * 2)
        context.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let string = ScreenshotTranslationLayout.attributedString(
            placement.text, fontSize: placement.fontSize, weight: placement.weight, color: .black,
            alignment: placement.alignment, lineHeight: placement.lineHeight, baselineOffset: placement.baselineOffset
        )
        ScreenshotTranslationLayout.TextLayout(string, size: placement.frame.size, exclusions: placement.exclusions, maximumLines: placement.maximumLines)
            .draw(at: placement.frame.origin)
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = PixelBuffer(image: context.makeImage()!) else { return nil }
        var rows: [Int] = []
        for y in 0..<pixels.height where (0..<pixels.width).contains(where: { pixels.pixel($0, y).r < 128 }) {
            rows.append(y)
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return CGFloat(first) / 2...CGFloat(last + 1) / 2
    }

    /// 审核第四轮（#12）：多行段落译成后备字体高的文字（缅甸文一行 31pt，14pt 原文的行距只有 20pt），
    /// 行高按原文行距、封顶 1.9 倍字号的话字会压到上下行、伸出排版范围。
    @Test func paragraphLineHeightFitsTallerFallbackScripts() throws {
        let burmese = String(repeating: "မြန်မာစာ ဘာသာပြန် ", count: 10)
        let lines = (0..<3).map { CGRect(x: 20, y: 30 + CGFloat($0) * 20, width: 300, height: 14) }
        let canvas = CGSize(width: 400, height: 300)
        let placement = try #require(ScreenshotTranslationLayout.plan(
            [block(burmese, lines: lines, limits: .init(minX: 20, maxX: 320, maxY: 280, minY: 10))],
            canvas: canvas
        ).first)
        let natural = ScreenshotTranslationLayout.systemMeasure(placement.text, placement.fontSize, placement.weight, nil, nil, []).size.height
        #expect(natural > 1.9 * placement.fontSize, "这组数据要是后备字体高的文字，才测得出来")
        #expect((placement.lineHeight ?? 0) >= natural - 0.5, "行高 \(placement.lineHeight ?? 0) 比译文本身的 \(natural) 矮")
        let ink = try #require(inkRows(of: placement, canvas: canvas))
        #expect(ink.lowerBound >= placement.frame.minY - 1 && ink.upperBound <= placement.frame.maxY + 1, "字画到了排版范围外面：\(ink) 对 \(placement.frame)")
    }

    /// 审核第四轮（#12）：单行也要查竖着放不放得下。上下都紧（按钮里）就缩小；只有下面有地方就往下挪、不缩。
    @Test func singleLineStaysWithinTheVerticalBounds() throws {
        let burmese = "မြန်မာစာ"
        let line = CGRect(x: 20, y: 40, width: 60, height: 14)
        let canvas = CGSize(width: 400, height: 300)
        func ink(_ placement: ScreenshotTranslationLayout.Placement) throws -> ClosedRange<CGFloat> {
            try #require(inkRows(of: placement, canvas: canvas))
        }
        let tight = ScreenshotTranslationLayout.Limits(minX: 10, maxX: 380, maxY: 57, minY: 37)
        let squeezed = try #require(ScreenshotTranslationLayout.plan([block(burmese, lines: [line], limits: tight)], canvas: canvas).first)
        #expect(squeezed.fontSize < 14)
        let squeezedInk = try ink(squeezed)
        #expect(squeezedInk.lowerBound >= tight.minY - 1 && squeezedInk.upperBound <= tight.maxY + 1, "墨迹 \(squeezedInk) 伸出了 \(tight.minY)…\(tight.maxY)")

        let roomBelow = ScreenshotTranslationLayout.Limits(minX: 10, maxX: 380, maxY: 120, minY: 40)
        let shifted = try #require(ScreenshotTranslationLayout.plan([block(burmese, lines: [line], limits: roomBelow)], canvas: canvas).first)
        #expect(shifted.fontSize == 14)
        #expect(try ink(shifted).lowerBound >= roomBelow.minY - 1)
    }

    @Test func paragraphShrinksWhenTheSpaceBelowIsTaken() throws {
        let lines = (0..<2).map { CGRect(x: 20, y: 10 + CGFloat($0) * 20, width: 200, height: 14) }
        // 60 个字在 14pt 要 5 行，只有两行多的地方：缩小，但不小于 62%。
        let placement = try place(block(String(repeating: "字", count: 60), lines: lines, limits: .init(minX: 20, maxX: 220, maxY: 60)))
        #expect(placement.fontSize < 14)
        #expect(placement.fontSize >= 14 * 0.62 - 0.01)
    }
}

@MainActor
@Suite("截图翻译：回贴图的状态")
struct ScreenshotOverlayStateTests {
    /// 审核第六轮（#12）：前几批画成功、后面一次画失败时，旧图（只有前几批的译文）要清掉，界面才会退回卡片列出最新的译文。
    @Test func failedRenderClearsTheStaleImage() {
        let session = ScreenshotOCRSession(sourceLanguageCode: LanguagePreset.auto.code, targetLanguageCode: "zh-CN")
        let image = NSImage(size: NSSize(width: 10, height: 10))
        session.applyOverlayRender(image)
        #expect(session.translatedImage === image)
        #expect(!session.overlayUnavailable)

        session.applyOverlayRender(nil)
        #expect(session.translatedImage == nil)
        #expect(session.overlayUnavailable)

        session.applyOverlayRender(image)
        #expect(session.translatedImage === image)
        #expect(!session.overlayUnavailable)
    }
}

@MainActor
@Suite("截图翻译：回贴渲染")
struct ScreenshotTranslationRendererTests {
    private struct Scene {
        let image: NSImage
        let cgImage: CGImage
        var pointSize: CGSize { image.size }
    }

    /// 在位图里画一张合成截图（默认 2 倍），左上原点、单位 pt。
    private func scene(width: CGFloat, height: CGFloat, scale: CGFloat = 2, draw: () -> Void) -> Scene {
        let context = CGContext(
            data: nil,
            width: Int(width * scale),
            height: Int(height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let cgImage = context.makeImage()!
        return Scene(image: NSImage(cgImage: cgImage, size: NSSize(width: width, height: height)), cgImage: cgImage)
    }

    private func scene(_ shot: SyntheticScreenshot) -> Scene {
        let image = shot.render()
        return Scene(image: image, cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    }

    private func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor = SyntheticScreenshot.ink, weight: NSFont.Weight = .regular) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]).draw(at: point)
    }

    private func recognize(_ scene: Scene) async -> [VisionOCRService.OCRBlock] {
        await VisionOCRService.recognizeBlocks(from: scene.image, languageCode: LanguagePreset.auto.code)
    }

    private func recognize(_ image: CGImage, size: CGSize) async -> [VisionOCRService.OCRBlock] {
        await VisionOCRService.recognizeBlocks(from: NSImage(cgImage: image, size: size), languageCode: LanguagePreset.auto.code)
    }

    /// 按原文开头配译文，渲染。
    private func render(_ scene: Scene, _ blocks: [VisionOCRService.OCRBlock], _ table: [String: String]) throws -> CGImage {
        var translations: [UUID: String] = [:]
        for block in blocks {
            if let hit = table.first(where: { block.text.hasPrefix($0.key) }) { translations[block.id] = hit.value }
        }
        #expect(translations.count == table.count, "有的原文没认出来：\(blocks.map(\.text))")
        return try #require(ScreenshotTranslationRenderer.render(.init(
            image: scene.cgImage,
            pointSize: scene.pointSize,
            blocks: blocks,
            translations: translations
        )))
    }

    /// 选区内 pt 坐标（左上原点）的范围里，两张图最大的色差（平方）。
    private func maxDifference(_ a: CGImage, _ b: CGImage, in rect: CGRect) throws -> Int {
        let pa = try #require(PixelBuffer(image: a)), pb = try #require(PixelBuffer(image: b))
        var worst = 0
        for y in max(0, Int(rect.minY * 2))..<min(pa.height, Int(rect.maxY * 2)) {
            for x in max(0, Int(rect.minX * 2))..<min(pa.width, Int(rect.maxX * 2)) {
                worst = max(worst, pa.pixel(x, y).squaredDistance(to: pb.pixel(x, y)))
            }
        }
        return worst
    }

    private func rect(of block: VisionOCRService.OCRBlock, in size: CGSize) -> CGRect {
        CGRect(
            x: block.boundingBox.minX * size.width,
            y: (1 - block.boundingBox.maxY) * size.height,
            width: block.boundingBox.width * size.width,
            height: block.boundingBox.height * size.height
        )
    }

    @Test func translationReplacesTheOriginalInPlaceWithTheSameSize() async throws {
        let shot = scene(SyntheticScreenshot(name: "界面", width: 480, height: 170, background: NSColor(white: 0.96, alpha: 1), texts: [
            SyntheticText(text: "Notification Settings", x: 24, y: 18, size: 22, weight: .bold),
            SyntheticText(text: "Allow notifications on this Mac", x: 24, y: 64, size: 13),
            SyntheticText(text: "Show previews when unlocked", x: 24, y: 94, size: 13)
        ]))
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, [
            "Notification Settings": "通知设置",
            "Allow notifications": "允许在这台 Mac 上显示通知",
            "Show previews": "解锁时显示预览"
        ])

        let after = await recognize(output, size: shot.pointSize)
        let recognized = after.map(\.text).joined(separator: "\n")
        for original in ["Notification", "Allow", "previews"] {
            #expect(!recognized.contains(original), "原文还在：\(recognized)")
        }
        let pixels = try #require(PixelBuffer(image: output))
        let before = try #require(PixelBuffer(image: shot.cgImage))
        for (translation, original, size) in [("通知设置", "Notification", 22.0), ("允许在这台", "Allow", 13.0), ("解锁时", "Show", 13.0)] as [(String, String, CGFloat)] {
            let drawn = try #require(after.first { $0.text.contains(translation) }, "没认出译文：\(recognized)")
            let source = try #require(blocks.first { $0.text.hasPrefix(original) })
            // 位置：左边和竖直中心对得上原文。
            let drawnRect = rect(of: drawn, in: shot.pointSize), sourceRect = rect(of: source, in: shot.pointSize)
            #expect(abs(drawnRect.minX - sourceRect.minX) < 3, "\(translation) 横向偏了")
            #expect(abs(drawnRect.midY - sourceRect.midY) < 3, "\(translation) 竖向偏了")
            // 字号：量出来和原文一样大。
            let drawnSize = ScreenshotTranslationRenderer.measureStyle(of: drawn, in: pixels, scale: 2).fontSize
            let sourceSize = ScreenshotTranslationRenderer.measureStyle(of: source, in: before, scale: 2).fontSize
            #expect(abs(drawnSize - size) / size < 0.06, "\(translation) 画成了 \(drawnSize)pt")
            #expect(abs(sourceSize - size) / size < 0.06, "\(original) 量成了 \(sourceSize)pt")
        }
        // 粗细：粗体标题译出来还是粗体，正文还是常规体。
        let title = try #require(after.first { $0.text.contains("通知设置") })
        #expect(ScreenshotTranslationRenderer.measureStyle(of: title, in: pixels, scale: 2).weight != .regular)
        let body = try #require(after.first { $0.text.contains("允许在这台") })
        #expect(ScreenshotTranslationRenderer.measureStyle(of: body, in: pixels, scale: 2).weight == .regular)
    }

    @Test func untouchedBlocksStayPixelIdentical() async throws {
        let shot = scene(SyntheticScreenshot(name: "部分翻译", width: 420, height: 130, texts: [
            SyntheticText(text: "Download the latest version", x: 20, y: 16, size: 14),
            SyntheticText(text: "quarterly-report-final.xlsx", x: 20, y: 52, size: 14),
            SyntheticText(text: "Terms may change without notice", x: 20, y: 88, size: 14)
        ]))
        let blocks = await recognize(shot)
        // 第二段译文和原文一样（文件名），第三段没翻：都不该动。
        let output = try render(shot, blocks, [
            "Download": "下载最新版本",
            "quarterly-report": "quarterly-report-final.xlsx"
        ])
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 0, y: 44, width: 420, height: 86)) == 0)
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 0, y: 0, width: 420, height: 38)) > 0)
    }

    @Test func textAndBackgroundColorsArePreservedOnADarkScreen() async throws {
        let background = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
        let ink = NSColor(srgbRed: 0xE6 / 255, green: 0xB4 / 255, blue: 0x50 / 255, alpha: 1)
        let shot = scene(SyntheticScreenshot(name: "深色", width: 420, height: 80, background: background, texts: [
            SyntheticText(text: "Edited two hours ago by Jordan", x: 20, y: 26, size: 15, color: ink)
        ]))
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, ["Edited": "Jordan 于两小时前编辑"])
        let after = await recognize(output, size: shot.pointSize)
        let drawn = try #require(after.first { $0.text.contains("小时前") }, "\(after.map(\.text))")
        let style = ScreenshotTranslationRenderer.measureStyle(of: drawn, in: try #require(PixelBuffer(image: output)), scale: 2)
        #expect(style.textColor.distance(to: .init(r: 0xE6, g: 0xB4, b: 0x50)) < 30, "字的颜色变成了 \(style.textColor)")
        #expect(style.background.distance(to: .init(r: 0x1E, g: 0x1E, b: 0x1E)) < 4, "背景变成了 \(style.background)")
    }

    @Test func buttonTextStaysCenteredInsideTheButton() async throws {
        let button = CGRect(x: 30, y: 20, width: 150, height: 34)
        let shot = scene(width: 320, height: 80) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 80).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            let width = NSAttributedString(string: "Upgrade to Pro", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).size().width
            text("Upgrade to Pro", at: CGPoint(x: button.midX - width / 2, y: 28), size: 15, color: .white, weight: .semibold)
        }
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, ["Upgrade": "升级"])
        // 按钮外面一个像素都不动。
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 0, y: 0, width: 320, height: 18)) == 0)
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 0, y: 56, width: 320, height: 24)) == 0)
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 182, y: 0, width: 138, height: 80)) == 0)
        // 译文在按钮里居中：以原文的中心为准。
        let after = await recognize(output, size: shot.pointSize)
        let drawn = try #require(after.first { $0.text.contains("升级") }, "\(after.map(\.text))")
        let source = try #require(blocks.first { $0.text.hasPrefix("Upgrade") })
        #expect(abs(rect(of: drawn, in: shot.pointSize).midX - rect(of: source, in: shot.pointSize).midX) < 2)
        #expect(abs(rect(of: drawn, in: shot.pointSize).midX - button.midX) < 2)
    }

    /// 审核第四轮（#12）：按钮里的字译成缅甸文（15pt 时墨迹 22pt，「Continue」只有 12pt），紧凑的按钮（20pt 高）
    /// 装得下原文、装不下原字号的缅甸文：要缩小，不能伸出按钮的上下沿。
    @Test func tallScriptTranslationStaysInsideTheButton() async throws {
        let button = CGRect(x: 30, y: 20, width: 180, height: 20)
        let shot = scene(width: 320, height: 80) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 80).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            let width = NSAttributedString(string: "Continue", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).size().width
            let height = NSAttributedString(string: "Continue", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).size().height
            text("Continue", at: CGPoint(x: button.midX - width / 2, y: button.midY - height / 2), size: 15, color: .white, weight: .semibold)
        }
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, ["Continue": "ဆက်လုပ်ပါ"])
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 0, y: 0, width: 320, height: button.minY - 1)) == 0, "伸出了按钮上沿")
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 0, y: button.maxY + 1, width: 320, height: 80 - button.maxY - 1)) == 0, "伸出了按钮下沿")
        #expect(try maxDifference(shot.cgImage, output, in: button.insetBy(dx: 20, dy: 4)) > 0, "按钮里的字没画")
    }

    /// 白字蓝按钮放在白底上：按钮外面的白底和字同色，量墨迹上下边时不能当成字，不然矮按钮上的字号会量大。
    @Test func whiteTextOnACompactButtonIsMeasuredInsideTheButton() async throws {
        let button = CGRect(x: 30, y: 20, width: 180, height: 20)
        let shot = scene(width: 320, height: 80) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 80).fill()
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
            let string = NSAttributedString(string: "Continue", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            text("Continue", at: CGPoint(x: button.midX - string.size().width / 2, y: button.midY - string.size().height / 2), size: 15, color: .white, weight: .semibold)
        }
        let block = try #require(await recognize(shot).first)
        let style = ScreenshotTranslationRenderer.measureStyle(of: block, in: try #require(PixelBuffer(image: shot.cgImage)), scale: 2)
        #expect(abs(style.fontSize - 15) / 15 < 0.05, "量成了 \(style.fontSize)pt")
        #expect(style.lines[0].minY >= button.minY && style.lines[0].maxY <= button.maxY, "墨迹带 \(style.lines[0]) 伸出了按钮")
        #expect(style.weight != .regular)
    }

    @Test func longTranslationStopsBeforeTheSwitchOnTheRight() async throws {
        let toggle = CGRect(x: 250, y: 14, width: 44, height: 24)
        let shot = scene(width: 320, height: 52) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 52).fill()
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: toggle, xRadius: 12, yRadius: 12).fill()
            text("隐私与安全性", at: CGPoint(x: 20, y: 17), size: 14)
        }
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, ["隐私与安全性": "Privacy and Security Preferences"])
        #expect(try maxDifference(shot.cgImage, output, in: toggle.insetBy(dx: -2, dy: -2)) == 0)
        let after = await recognize(output, size: shot.pointSize)
        let drawn = try #require(after.first { $0.text.contains("Privacy") }, "\(after.map(\.text))")
        #expect(rect(of: drawn, in: shot.pointSize).maxX < toggle.minX)
    }

    @Test func paragraphKeepsAGapBeforeTheNextParagraph() async throws {
        let shot = scene(SyntheticScreenshot(name: "段落", width: 420, height: 150, texts:
            SyntheticScreenshot.lines(["为了保护你的账户安全，我们会在检测到异常登录", "时向你发送验证码，请勿将验证码告诉他人。"], x: 16, top: 14, size: 14, lineHeight: 22)
            + [SyntheticText(text: "客服电话 400-000-0000", x: 16, y: 66, size: 14, color: SyntheticScreenshot.gray)]))
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, [
            "为了保护": "To keep your account secure, we will send you a verification code whenever we detect an unusual sign-in attempt. Never share this code with anyone."
        ])
        let after = await recognize(output, size: shot.pointSize)
        let next = try #require(after.first { $0.text.contains("400") }, "\(after.map(\.text))")
        let paragraph = try #require(after.first { $0.text.contains("account") }, "\(after.map(\.text))")
        let gap = rect(of: next, in: shot.pointSize).minY - rect(of: paragraph, in: shot.pointSize).maxY
        #expect(gap > 3, "译文和下一段只隔了 \(gap)pt")
    }

    @Test func erasingOnAGradientLeavesNoPatch() async throws {
        let shot = scene(width: 400, height: 90) {
            NSGradient(
                starting: NSColor(srgbRed: 0.29, green: 0.56, blue: 0.89, alpha: 1),
                ending: NSColor(srgbRed: 0.56, green: 0.07, blue: 1, alpha: 1)
            )!.draw(in: NSRect(x: 0, y: 0, width: 400, height: 90), angle: 0)
            text("Welcome back, Alex", at: CGPoint(x: 24, y: 28), size: 22, color: .white, weight: .bold)
        }
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, ["Welcome": "你好"])
        // 译文只占前面一小截；原文后半截抹掉的地方要和同一列上没有字的地方一个颜色（横向渐变，每一列同色）。
        let pixels = try #require(PixelBuffer(image: output))
        var worst = 0
        for x in stride(from: 2 * 120, to: 2 * 230, by: 3) {
            let reference = pixels.pixel(x, 2 * 8)
            for y in stride(from: 2 * 28, to: 2 * 56, by: 2) {
                worst = max(worst, pixels.pixel(x, y).squaredDistance(to: reference))
            }
        }
        #expect(worst <= 8 * 8, "抹过的地方和四周差了 \(Double(worst).squareRoot())")
    }

    @Test func fontSizeAndWeightAreMeasuredAcrossScriptsAndThemes() async throws {
        for dark in [false, true] {
            for text in ["Allow notifications on this Mac", "允许在这台电脑上显示通知"] {
                for size in [13, 22] as [CGFloat] {
                    for weight in [NSFont.Weight.regular, .semibold] {
                        let shot = scene(SyntheticScreenshot(
                            name: "",
                            width: 520,
                            height: 70,
                            background: dark ? NSColor(white: 0.12, alpha: 1) : .white,
                            texts: [SyntheticText(text: text, x: 20, y: 18, size: size, weight: weight, color: dark ? .white : SyntheticScreenshot.ink)]
                        ))
                        let block = try #require(await recognize(shot).first)
                        let style = ScreenshotTranslationRenderer.measureStyle(of: block, in: try #require(PixelBuffer(image: shot.cgImage)), scale: 2)
                        let label = "\(text.prefix(5)) \(size)pt \(weight == .regular ? "常规" : "半粗") \(dark ? "深色" : "浅色")"
                        #expect(abs(style.fontSize - size) / size < 0.05, "\(label) 量成了 \(style.fontSize)pt")
                        #expect((style.weight == .regular) == (weight == .regular), "\(label) 粗细判成了 \(style.weight.rawValue)")
                    }
                }
            }
        }
    }

    /// 审核第一轮（#12）：1 倍屏上 0.15 个字宽才一个多像素，扫描不能把自己最后一笔竖画当成障碍。
    @Test func smallTextOnA1xScreenStillGrowsIntoEmptySpace() async throws {
        let shot = scene(SyntheticScreenshot(name: "1x", width: 360, height: 40, scale: 1, texts: [
            SyntheticText(text: "Install", x: 20, y: 12, size: 11)
        ]))
        let block = try #require(await recognize(shot).first)
        let style = ScreenshotTranslationRenderer.measureStyle(of: block, in: try #require(PixelBuffer(image: shot.cgImage)), scale: 1)
        #expect(style.limits.maxX > 340, "右边全是空白，却只能长到 \(style.limits.maxX)")
        #expect(style.limits.minX < 10, "左边全是空白，却只能长到 \(style.limits.minX)")

        let layout = ScreenshotTranslationLayout.Block(
            id: block.id,
            text: "安装并重新启动所有的应用程序",
            lines: style.lines,
            fontSize: style.fontSize,
            weight: style.weight,
            alignment: style.alignment,
            limits: style.limits
        )
        let placement = try #require(ScreenshotTranslationLayout.plan([layout], canvas: shot.pointSize).first)
        #expect(placement.fontSize == style.fontSize, "有空白却缩到了 \(placement.fontSize)pt")
    }

    /// 审核第一轮（#12）：带边框的一行里两个等距的标签都判成居中，译文都变长时不能叠在一起。
    @Test func evenlySpacedLabelsInABorderedRowDoNotOverlap() async throws {
        let row = CGRect(x: 20, y: 16, width: 280, height: 30)
        let font = NSFont.systemFont(ofSize: 14)
        let widths = ["Home", "Mail"].map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
        let gap = (row.width - widths[0] - widths[1]) / 3
        let shot = scene(width: 320, height: 62) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 320, height: 62).fill()
            NSColor(white: 0.75, alpha: 1).setStroke()
            NSBezierPath(rect: row).stroke()
            text("Home", at: CGPoint(x: row.minX + gap, y: 22), size: 14)
            text("Mail", at: CGPoint(x: row.minX + 2 * gap + widths[0], y: 22), size: 14)
        }
        let blocks = await recognize(shot)
        let pixels = try #require(PixelBuffer(image: shot.cgImage))
        let home = try #require(blocks.first { $0.text.hasPrefix("Home") })
        let mail = try #require(blocks.first { $0.text.hasPrefix("Mail") })
        let styles = [home, mail].map { ScreenshotTranslationRenderer.measureStyle(of: $0, in: pixels, scale: 2) }
        #expect(styles.allSatisfy { $0.alignment == .center }, "两个标签都该判成居中，这个用例才测得到抢空白")

        let texts = ["返回首页查看最新的内容", "查看收件箱里所有的邮件"]
        let layout = zip(zip([home, mail], styles), texts).map { pair, text in
            ScreenshotTranslationLayout.Block(id: pair.0.id, text: text, lines: pair.1.lines, fontSize: pair.1.fontSize, weight: pair.1.weight, alignment: pair.1.alignment, limits: pair.1.limits)
        }
        let placements = ScreenshotTranslationLayout.plan(layout, canvas: shot.pointSize)
        #expect(!placements[0].frame.intersects(placements[1].frame))

        // 画出来：两段原文正中间那一列上没有字。
        let output = try render(shot, blocks, ["Home": texts[0], "Mail": texts[1]])
        let rendered = try #require(PixelBuffer(image: output))
        let middle = Int((styles[0].lines[0].maxX + styles[1].lines[0].minX) * 2 / 2)  // 两段中点（像素）
        for y in stride(from: Int(row.minY * 2) + 6, to: Int(row.maxY * 2) - 6, by: 1) {
            #expect(rendered.pixel(middle, y).distance(to: .init(r: 255, g: 255, b: 255)) < 30, "中线上 y=\(y) 有字")
        }
    }

    /// 审核第二轮（#12）：段落第一行长、第二行短，短行旁边有个图标——在段落外框里面。译文变长也不能画到图标上。
    @Test func translationDoesNotPaintOverAnIconBesideAShortLine() async throws {
        let first = "Your subscription renews automatically every month and"
        let font = NSFont.systemFont(ofSize: 14)
        let secondWidth = NSAttributedString(string: "can be cancelled", attributes: [.font: font]).size().width
        let icon = CGRect(x: 16 + secondWidth + 40, y: 38, width: 18, height: 18)
        let shot = scene(width: 460, height: 120) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 460, height: 120).fill()
            text(first, at: CGPoint(x: 16, y: 14), size: 14)
            text("can be cancelled", at: CGPoint(x: 16, y: 38), size: 14)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: icon).fill()
        }
        let blocks = await recognize(shot)
        let paragraph = try #require(blocks.first { $0.text.hasPrefix("Your subscription") })
        #expect(paragraph.lines.count == 2, "两行要拼成一段，这个用例才测得到段落外框里的空当：\(blocks.map(\.text))")
        let style = ScreenshotTranslationRenderer.measureStyle(of: paragraph, in: try #require(PixelBuffer(image: shot.cgImage)), scale: 2)
        #expect(!style.obstacles.isEmpty, "短行旁边的图标没被认成障碍")

        let translation = "你的订阅会每个月自动续费，而且你随时都可以在账户设置里面取消这个订阅，取消之后本期结束前仍然可以继续使用全部功能。"
        // 下面还有空地方：图标只挡住右边一截，段落照样能往下长，不用把字缩小。
        let layout = ScreenshotTranslationLayout.Block(
            id: paragraph.id, text: translation, lines: style.lines, fontSize: style.fontSize, weight: style.weight,
            alignment: style.alignment, limits: style.limits, obstacles: style.obstacles
        )
        let placement = try #require(ScreenshotTranslationLayout.plan([layout], canvas: shot.pointSize).first)
        #expect(placement.fontSize == style.fontSize, "图标把整段都挡住了，字缩到了 \(placement.fontSize)pt")
        // 图标只在第二行旁边：没有哪一行被它劈成左右两截。
        let string = ScreenshotTranslationLayout.attributedString(
            placement.text, fontSize: placement.fontSize, weight: placement.weight, color: .black,
            alignment: placement.alignment, lineHeight: placement.lineHeight
        )
        let fragments = ScreenshotTranslationLayout.TextLayout(string, size: placement.frame.size, exclusions: placement.exclusions, maximumLines: placement.maximumLines).lineRects
        #expect(Set(fragments.map { Int($0.minY.rounded()) }).count == fragments.count, "有一行被劈成了两截：\(fragments)")

        // 只绕开图标实际占的那几行：图标下面的地方照样排字，不留一截空。
        for obstacle in style.obstacles {
            #expect(obstacle.maxY <= icon.maxY + 0.6 * style.fontSize, "绕开的地方 \(obstacle) 一直伸到了图标下面")
        }

        let output = try render(shot, blocks, ["Your subscription": translation])
        #expect(try maxDifference(shot.cgImage, output, in: icon.insetBy(dx: -1, dy: -1)) == 0)
        // 第一行确实被换掉了（不是整段没画）。
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: 16, y: 14, width: 300, height: 16)) > 0)
    }

    /// 审核第三轮（#12）：真实截图——段落短行旁边是一个单独的标签，两段都译长，段落的字不压到标签的译文。
    @Test func translatedLabelBesideAShortParagraphLineDoesNotCollide() async throws {
        let font = NSFont.systemFont(ofSize: 14)
        let secondWidth = NSAttributedString(string: "can be cancelled", attributes: [.font: font]).size().width
        // 选区收窄：标签的译文在右边一行放不下，只能折行往下长，和段落往下长的第三行抢地方。
        let shot = scene(width: 390, height: 130) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 390, height: 130).fill()
            text("Your subscription renews automatically every month and", at: CGPoint(x: 16, y: 14), size: 14)
            text("can be cancelled", at: CGPoint(x: 16, y: 38), size: 14)
            text("Details", at: CGPoint(x: 16 + secondWidth + 90, y: 38), size: 14, color: .systemBlue)
        }
        let blocks = await recognize(shot)
        let paragraph = try #require(blocks.first { $0.text.hasPrefix("Your subscription") })
        let label = try #require(blocks.first { $0.text == "Details" }, "标签要单独成段：\(blocks.map(\.text))")
        #expect(paragraph.lines.count == 2)
        let pixels = try #require(PixelBuffer(image: shot.cgImage))
        let styles = [paragraph, label].map { ScreenshotTranslationRenderer.measureStyle(of: $0, in: pixels, scale: 2) }
        let texts = ["你的订阅会每个月自动续费，而且你随时都可以在账户设置里面取消这个订阅，取消之后本期结束前仍然可以继续使用全部功能。", "查看这项订阅的详细信息和历史账单"]
        let layout = zip(zip([paragraph, label], styles), texts).map { pair, text in
            ScreenshotTranslationLayout.Block(
                id: pair.0.id, text: text, lines: pair.1.lines, fontSize: pair.1.fontSize, weight: pair.1.weight,
                alignment: pair.1.alignment, limits: pair.1.limits, obstacles: pair.1.obstacles
            )
        }
        func collides(_ host: ScreenshotTranslationLayout.Placement, _ guest: ScreenshotTranslationLayout.Placement) -> Bool {
            let string = ScreenshotTranslationLayout.attributedString(host.text, fontSize: host.fontSize, weight: host.weight, color: .black, alignment: host.alignment, lineHeight: host.lineHeight)
            return ScreenshotTranslationLayout.TextLayout(string, size: host.frame.size, exclusions: host.exclusions, maximumLines: host.maximumLines)
                .lineRects.map { $0.offsetBy(dx: host.frame.minX, dy: host.frame.minY) }
                .contains { $0.insetBy(dx: 0, dy: 0.12 * host.fontSize).intersects(guest.frame.insetBy(dx: 0, dy: 0.12 * guest.fontSize)) }
        }
        let alone = layout.compactMap { ScreenshotTranslationLayout.plan([$0], canvas: shot.pointSize).first }
        #expect(collides(alone[0], alone[1]), "各排各的本来就会撞，这个用例才测得出来")

        let placements = ScreenshotTranslationLayout.plan(layout, canvas: shot.pointSize)
        #expect(!collides(placements[0], placements[1]))
    }

    /// 审核第五轮（#12）：单个汉字「工」「王」的一横能占满文字框，不能当成按钮外面的底色——墨迹带要盖住整个字，
    /// 抹字才抹得干净。
    @Test func singleCharacterWithAWideStrokeIsErasedCompletely() async throws {
        for character in ["工", "王"] {
            let origin = CGPoint(x: 40, y: 20)
            let shot = scene(width: 200, height: 70) {
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 200, height: 70).fill()
                text(character, at: origin, size: 24)
            }
            // 真正的字形范围：原图上深色像素的上下左右。
            let original = try #require(PixelBuffer(image: shot.cgImage))
            var rows: [Int] = [], columns: [Int] = []
            for y in 0..<original.height {
                for x in 0..<original.width where original.pixel(x, y).r < 160 {
                    rows.append(y)
                    columns.append(x)
                }
            }
            let glyph = CGRect(
                x: CGFloat(columns.min()!) / 2, y: CGFloat(rows.min()!) / 2,
                width: CGFloat(columns.max()! - columns.min()! + 1) / 2, height: CGFloat(rows.max()! - rows.min()! + 1) / 2
            )

            let blocks = await recognize(shot)
            let block = try #require(blocks.first { $0.text == character }, "\(character) 没认出来：\(blocks.map(\.text))")
            let style = ScreenshotTranslationRenderer.measureStyle(of: block, in: original, scale: 2)
            #expect(style.lines[0].minY <= glyph.minY + 0.5 && style.lines[0].maxY >= glyph.maxY - 0.5, "\(character) 的墨迹带 \(style.lines[0]) 没盖住整个字 \(glyph)")

            // 译成一个很小的「.」：除了新画的那一点，原来字的地方一个深色像素都不该剩。
            let output = try #require(ScreenshotTranslationRenderer.render(.init(
                image: shot.cgImage, pointSize: shot.pointSize, blocks: [block], translations: [block.id: "."]
            )))
            let rendered = try #require(PixelBuffer(image: output))
            let dot = try #require(ScreenshotTranslationLayout.plan([ScreenshotTranslationLayout.Block(
                id: block.id, text: ".", lines: style.lines, fontSize: style.fontSize, weight: style.weight,
                alignment: style.alignment, limits: style.limits, obstacles: style.obstacles
            )], canvas: shot.pointSize).first).frame
            var leftover = 0
            for y in Int(glyph.minY * 2)...Int(glyph.maxY * 2) {
                for x in Int(glyph.minX * 2)...Int(glyph.maxX * 2) where rendered.pixel(x, y).r < 160 && !dot.contains(CGPoint(x: CGFloat(x) / 2, y: CGFloat(y) / 2)) {
                    leftover += 1
                }
            }
            #expect(leftover == 0, "\(character) 还剩 \(leftover) 个深色像素没抹掉")
        }
    }

    /// 审核第五轮（#12）：1 倍屏上字后面紧贴着（两个像素）一条 1 像素的竖分隔线，扫描起点跳过了它；
    /// 长译文不能越过分隔线伸进隔壁的单元格。
    @Test func dividerRightAfterTheTextStopsTheTranslation() async throws {
        let font = NSFont.systemFont(ofSize: 14)
        let origin = CGPoint(x: 20, y: 12)
        let inkMaxX = origin.x + CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(NSAttributedString(string: "Install", attributes: [.font: font])), .useGlyphPathBounds
        ).maxX
        let divider = CGRect(x: ceil(inkMaxX) + 2, y: 2, width: 1, height: 36)
        let shot = scene(width: 360, height: 40, scale: 1) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 360, height: 40).fill()
            text("Install", at: origin, size: 14)
            NSColor(white: 0.8, alpha: 1).setFill()
            divider.fill()
        }
        let block = try #require(await recognize(shot).first { $0.text.hasPrefix("Install") })
        let style = ScreenshotTranslationRenderer.measureStyle(of: block, in: try #require(PixelBuffer(image: shot.cgImage)), scale: 1)
        #expect(style.limits.maxX <= divider.minX, "越过了分隔线：能长到 \(style.limits.maxX)，分隔线在 \(divider.minX)")
        let placement = try #require(ScreenshotTranslationLayout.plan([ScreenshotTranslationLayout.Block(
            id: block.id, text: "安装并重新启动应用程序", lines: style.lines, fontSize: style.fontSize, weight: style.weight,
            alignment: style.alignment, limits: style.limits, obstacles: style.obstacles
        )], canvas: shot.pointSize).first)
        #expect(placement.frame.maxX <= divider.minX + 0.5)

        // 审核第六轮：画出来也不能把分隔线抹掉。
        let output = try #require(ScreenshotTranslationRenderer.render(.init(
            image: shot.cgImage, pointSize: shot.pointSize, blocks: [block], translations: [block.id: "安装并重新启动应用程序"]
        )))
        let rendered = try #require(PixelBuffer(image: output)), original = try #require(PixelBuffer(image: shot.cgImage))
        for y in Int(divider.minY)..<Int(divider.maxY) {
            #expect(rendered.pixel(Int(divider.minX), y) == original.pixel(Int(divider.minX), y), "分隔线 y=\(y) 被动了")
        }
    }

    /// 审核第六轮（#12）：抹字的外扩边距不能越过旁边的东西。24pt 黑字离浅灰分隔线只有 1pt，
    /// 外扩 0.12 个字宽（2.88pt）会把分隔线也抹掉。
    @Test func erasingKeepsADividerOnePointAfterTheText() async throws {
        let font = NSFont.systemFont(ofSize: 24)
        let origin = CGPoint(x: 20, y: 14)
        let inkMaxX = origin.x + CTLineGetBoundsWithOptions(
            CTLineCreateWithAttributedString(NSAttributedString(string: "Install", attributes: [.font: font])), .useGlyphPathBounds
        ).maxX
        let divider = CGRect(x: ceil(inkMaxX) + 1, y: 4, width: 1, height: 52)
        let shot = scene(width: 360, height: 60) {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 360, height: 60).fill()
            text("Install", at: origin, size: 24)
            NSColor(white: 0.82, alpha: 1).setFill()
            divider.fill()
        }
        let blocks = await recognize(shot)
        let output = try render(shot, blocks, ["Install": "安装"])
        #expect(try maxDifference(shot.cgImage, output, in: divider) == 0, "分隔线被抹掉了")
        #expect(try maxDifference(shot.cgImage, output, in: CGRect(x: origin.x, y: origin.y, width: divider.minX - origin.x - 1, height: 30)) > 0, "原文没换掉")
    }

    /// 审核第六轮后自查（#12）：行距紧、第二行的行框往上伸进第一行（Vision 的行框会忽高忽低）时，两行的墨迹带
    /// 叠在一起（各自扩进了对方）。按两行中线分开抹会削进第一行自己的字，它比第二行长出来的那一截，字的下沿漏抹。
    @Test func tightParagraphLinesAreErasedCompletely() throws {
        let font = NSFont.systemFont(ofSize: 14)
        let size = CGSize(width: 300, height: 60)
        func width(_ string: String) -> CGFloat { NSAttributedString(string: string, attributes: [.font: font]).size().width }
        func normalized(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX / size.width, y: 1 - rect.maxY / size.height, width: rect.width / size.width, height: rect.height / size.height)
        }
        let white = PixelBuffer.RGB(r: 255, g: 255, b: 255)
        for (first, second, pitch) in [("gypqgypqgypqgypqgypqgypq", "ÂÊÎÔ", CGFloat(14)), ("排版引擎在紧凑的段落里测量墨迹带", "中文短行", 15)] {
            let shot = scene(width: size.width, height: size.height) {
                NSColor.white.setFill()
                NSRect(origin: .zero, size: size).fill()
                text(first, at: CGPoint(x: 10, y: 8), size: 14)
                text(second, at: CGPoint(x: 10, y: 8 + pitch), size: 14)
            }
            let block = VisionOCRService.OCRBlock(text: first + second, lines: [
                .init(text: first, boundingBox: normalized(CGRect(x: 10, y: 9.5, width: width(first), height: 13.7))),
                .init(text: second, boundingBox: normalized(CGRect(x: 10, y: 4.5 + pitch, width: width(second), height: 18.7)))
            ])
            let style = ScreenshotTranslationRenderer.measureStyle(of: block, in: try #require(PixelBuffer(image: shot.cgImage)), scale: 2)
            #expect(style.lines[0].maxY > style.lines[1].minY, "\(first)：两行的墨迹带没叠在一起，场景没搭对")
            for (line, erase) in zip(style.lines, style.eraseRects) {
                #expect(erase.contains(line), "\(first)：抹字范围 \(erase) 没盖住墨迹带 \(line)")
            }

            let output = try #require(ScreenshotTranslationRenderer.render(.init(
                image: shot.cgImage, pointSize: size, blocks: [block], translations: [block.id: "短句"]
            )))
            let rendered = try #require(PixelBuffer(image: output))
            // 第一行比第二行长出来的那一截（新画的「短句」在最左边，不在这里）：原来的字一个深色像素都不剩。
            let region = CGRect(x: style.lines[1].maxX + 20, y: 4, width: style.lines[0].maxX - style.lines[1].maxX - 20, height: 40)
            var dark = 0
            for y in Int(region.minY * 2)..<Int(region.maxY * 2) {
                for x in Int(region.minX * 2)..<Int(region.maxX * 2) where rendered.pixel(x, y).squaredDistance(to: white) > 900 {
                    dark += 1
                }
            }
            #expect(dark == 0, "\(first)：第一行长出来的那一截还剩 \(dark) 个深色像素没抹掉")
        }
    }

    @Test func renderingWithoutChangesReturnsTheOriginalImage() async throws {
        let shot = scene(SyntheticScreenshot(name: "", width: 300, height: 60, texts: [SyntheticText(text: "Hello world", x: 20, y: 20, size: 14)]))
        let blocks = await recognize(shot)
        let output = try #require(ScreenshotTranslationRenderer.render(.init(image: shot.cgImage, pointSize: shot.pointSize, blocks: blocks, translations: [:])))
        #expect(output === shot.cgImage)
    }
}
