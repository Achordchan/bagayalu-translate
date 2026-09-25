//
//  ScreenshotOCRTestSupport.swift
//  dazuofanyiguanTests
//
//  截图 OCR 测试用的合成截图：按指定字号、颜色把文字画进 2x 位图，标准答案就是画进去的文字。
//

import AppKit
@testable import 大佐翻译官v1

struct SyntheticText {
    let text: String
    let x: CGFloat
    /// 距顶部的距离（pt）。
    let y: CGFloat
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    var color: NSColor = SyntheticScreenshot.ink
    /// 文字底下垫一块圆角色块（按钮、标签）。
    var pill: NSColor? = nil
}

struct SyntheticScreenshot {
    static let ink = NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
    static let gray = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)

    let name: String
    let width: CGFloat
    let height: CGFloat
    var scale: CGFloat = 2
    var background: NSColor = .white
    let texts: [SyntheticText]

    var groundTruth: String { texts.map(\.text).joined(separator: "\n") }

    /// 连续几行，行距固定。
    static func lines(
        _ strings: [String],
        x: CGFloat = 24,
        top: CGFloat,
        size: CGFloat,
        lineHeight: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = ink
    ) -> [SyntheticText] {
        strings.enumerated().map { index, text in
            SyntheticText(text: text, x: x, y: top + CGFloat(index) * lineHeight, size: size, weight: weight, color: color)
        }
    }

    @MainActor
    func render() -> NSImage {
        let pixelWidth = Int(width * scale)
        let pixelHeight = Int(height * scale)
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
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
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for item in texts {
            let string = NSAttributedString(string: item.text, attributes: [
                .font: NSFont.systemFont(ofSize: item.size, weight: item.weight),
                .foregroundColor: item.color
            ])
            if let pill = item.pill {
                let size = string.size()
                pill.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: item.x - 10, y: item.y - 5, width: size.width + 20, height: size.height + 10),
                    xRadius: 7,
                    yRadius: 7
                ).fill()
            }
            string.draw(at: NSPoint(x: item.x, y: item.y))
        }
        NSGraphicsContext.restoreGraphicsState()

        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }
}

/// 字符错误率：编辑距离 / 标准答案长度，忽略所有空白（段落拼接会改变空格和换行）。
func characterErrorRate(expected: String, actual: String) -> Double {
    func normalized(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace })
    }
    let a = normalized(expected)
    let b = normalized(actual)
    if a.isEmpty { return b.isEmpty ? 0 : 1 }
    if b.isEmpty { return 1 }

    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
            )
        }
        swap(&previous, &current)
    }
    return Double(previous[b.count]) / Double(a.count)
}

extension SyntheticScreenshot {
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// 识别基准：各语言、深浅色、彩色标签、浅灰小字、代码网址。
    /// 2026-09-26 在 macOS 26.5 上逐张实测字符错误率都是 0。
    static let benchmark: [SyntheticScreenshot] = [
        SyntheticScreenshot(name: "英文界面", width: 560, height: 300, background: hex(0xF5F5F7), texts:
            [SyntheticText(text: "Notification Settings", x: 24, y: 18, size: 22, weight: .bold)]
            + lines(["Allow notifications on this Mac", "Show previews: When Unlocked", "Notification grouping: Automatic"], top: 64, size: 13, lineHeight: 30)
            + [SyntheticText(text: "Save Changes", x: 34, y: 170, size: 13, weight: .semibold, color: .white, pill: hex(0x0A84FF))]
            + lines(["Changes apply to all devices signed in with your Apple Account."], top: 230, size: 11, lineHeight: 18, color: gray)),
        SyntheticScreenshot(name: "英文文章", width: 640, height: 260, texts:
            [SyntheticText(text: "Why the Ocean Is Getting Louder", x: 24, y: 16, size: 26, weight: .bold)]
            + lines([
                "Shipping traffic has doubled the background noise in many parts of the",
                "ocean since the 1960s. Whales that rely on sound to find food and mates",
                "now have to call louder and more often, and some have stopped singing",
                "altogether when large vessels pass nearby."
            ], top: 66, size: 15, lineHeight: 24)
            + [SyntheticText(text: "Photo: NOAA Fisheries / Updated March 3, 2026", x: 24, y: 180, size: 11, color: gray)]),
        SyntheticScreenshot(name: "深色界面", width: 560, height: 200, background: hex(0x1E1E1E), texts:
            [SyntheticText(text: "Recent Projects", x: 24, y: 16, size: 17, weight: .semibold, color: hex(0xE6E6E6))]
            + lines(["quarterly-report-final.xlsx", "Edited 2 hours ago by Jordan Lee"], top: 54, size: 13, lineHeight: 26, color: hex(0xE6E6E6))
            + [SyntheticText(text: "Open the file browser to see all 128 items.", x: 24, y: 130, size: 12, color: hex(0x9A9A9A))]),
        SyntheticScreenshot(name: "彩色标签", width: 560, height: 170, texts: [
            SyntheticText(text: "Payment failed", x: 34, y: 20, size: 14, weight: .semibold, color: hex(0xD93025), pill: hex(0xFCE8E6)),
            SyntheticText(text: "Your card was declined by the issuing bank.", x: 34, y: 60, size: 13, color: hex(0xB3261E)),
            SyntheticText(text: "Upgrade to Pro", x: 34, y: 104, size: 13, weight: .semibold, color: .white, pill: hex(0x1A73E8)),
            SyntheticText(text: "Only 3 seats left at this price", x: 200, y: 104, size: 13, weight: .medium, color: hex(0xE8710A))
        ]),
        SyntheticScreenshot(name: "浅灰小字", width: 560, height: 110, texts:
            lines(["This offer expires on Friday at midnight.", "Terms may change without prior notice."], top: 14, size: 12, lineHeight: 26, color: hex(0xB0B0B0))),
        SyntheticScreenshot(name: "中文", width: 560, height: 170, texts:
            [SyntheticText(text: "系统更新说明", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["本次更新修复了若干已知问题，并提升了电池续航表现。", "如需帮助，请访问支持页面或联系客服。"], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "日文", width: 560, height: 170, texts:
            [SyntheticText(text: "お知らせ", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["明日の午前二時から四時まで、システムのメンテナンスを行います。", "ご不便をおかけして申し訳ございません。"], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "韩文", width: 560, height: 150, texts:
            [SyntheticText(text: "배송 안내", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["주문하신 상품이 오늘 출고되었습니다."], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "法文", width: 600, height: 150, texts:
            [SyntheticText(text: "Préférences du compte", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["Vous pouvez modifier votre adresse électronique à tout moment."], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "德文", width: 600, height: 150, texts:
            [SyntheticText(text: "Größe und Gewicht", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["Rücksendungen sind bis zu dreißig Tage nach Erhalt möglich."], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "俄文", width: 600, height: 150, texts:
            [SyntheticText(text: "Настройки безопасности", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["Мы заметили вход в ваш аккаунт с нового устройства."], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "西文", width: 600, height: 150, texts:
            [SyntheticText(text: "¿Necesitas ayuda con tu pedido?", x: 24, y: 16, size: 20, weight: .bold)]
            + lines(["Recibimos tu solicitud y la revisaremos en las próximas horas."], top: 58, size: 14, lineHeight: 26)),
        SyntheticScreenshot(name: "代码网址", width: 600, height: 110, background: hex(0xFAFAFA), texts:
            lines(["Error 404: https://api.example.com/v2/users?id=42&page=3", "Run npm install --save-dev typescript@5.4.2 to fix it."], top: 16, size: 13, lineHeight: 28))
    ]
}
