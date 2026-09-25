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
    private let measure: ScreenshotTranslationLayout.Measure = { text, fontSize, _, width, lineHeight in
        let natural = CGFloat(text.count) * 0.6 * fontSize
        let line = lineHeight ?? 1.2 * fontSize
        guard let width else { return CGSize(width: natural, height: line) }
        let lines = max(1, Int((natural / width).rounded(.up)))
        return CGSize(width: min(natural, width), height: CGFloat(lines) * line)
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

    @Test func paragraphShrinksWhenTheSpaceBelowIsTaken() throws {
        let lines = (0..<2).map { CGRect(x: 20, y: 10 + CGFloat($0) * 20, width: 200, height: 14) }
        // 60 个字在 14pt 要 5 行，只有两行多的地方：缩小，但不小于 62%。
        let placement = try place(block(String(repeating: "字", count: 60), lines: lines, limits: .init(minX: 20, maxX: 220, maxY: 60)))
        #expect(placement.fontSize < 14)
        #expect(placement.fontSize >= 14 * 0.62 - 0.01)
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

    /// 在 2 倍位图里画一张合成截图，左上原点、单位 pt。
    private func scene(width: CGFloat, height: CGFloat, draw: () -> Void) -> Scene {
        let scale: CGFloat = 2
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

    @Test func renderingWithoutChangesReturnsTheOriginalImage() async throws {
        let shot = scene(SyntheticScreenshot(name: "", width: 300, height: 60, texts: [SyntheticText(text: "Hello world", x: 20, y: 20, size: 14)]))
        let blocks = await recognize(shot)
        let output = try #require(ScreenshotTranslationRenderer.render(.init(image: shot.cgImage, pointSize: shot.pointSize, blocks: blocks, translations: [:])))
        #expect(output === shot.cgImage)
    }
}
