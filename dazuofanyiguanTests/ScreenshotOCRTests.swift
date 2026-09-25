//
//  ScreenshotOCRTests.swift
//  dazuofanyiguanTests
//
//  截图翻译的识别链路：段落拼接、源语言、逐段判断源语言，以及用合成截图跑真实 Vision 的回归。
//

import AppKit
import OpenAI
import Testing
@testable import 大佐翻译官v1

@Suite("截图 OCR：段落拼接")
@MainActor
struct OCRParagraphGrouperTests {
    private let canvas = CGSize(width: 600, height: 400)

    /// 造一行：宽度用系统字体真实量出来（和 Vision 在截图上量到的一致），框高取字号的 1.1 倍。
    /// 坐标是左上原点的 pt，换算成 Vision 的标准化坐标（左下原点）。
    private func line(
        _ text: String,
        x: CGFloat,
        top: CGFloat,
        size: CGFloat = 15,
        weight: NSFont.Weight = .regular,
        in canvasSize: CGSize? = nil
    ) -> VisionOCRService.OCRLine {
        let canvasSize = canvasSize ?? canvas
        let width = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]
        ).size().width
        let height = size * 1.1
        return VisionOCRService.OCRLine(
            text: text,
            boundingBox: CGRect(
                x: x / canvasSize.width,
                y: 1 - (top + height) / canvasSize.height,
                width: width / canvasSize.width,
                height: height / canvasSize.height
            )
        )
    }

    private func group(_ lines: [VisionOCRService.OCRLine], in canvasSize: CGSize? = nil) -> [String] {
        OCRParagraphGrouper.group(lines, imageSize: canvasSize ?? canvas).map(\.text)
    }

    @Test func estimatedEmMatchesTheRenderedFontSize() {
        for (text, size) in [("ocean since the 1960s. Whales that rely on sound to find food and mates", CGFloat(15)),
                             ("Why the Ocean Is Getting Louder", CGFloat(26)),
                             ("本次更新修复了若干已知问题，并提升了电池续航表现。", CGFloat(14))] {
            let width = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]).size().width
            let em = OCRParagraphGrouper.estimatedEm(width: width, text: text)
            #expect(abs(em - size) / size < 0.12, "\(text)：估算 \(em)，实际 \(size)")
        }
    }

    @Test func wrappedParagraphBecomesOneBlock() {
        let blocks = group([
            line("Shipping traffic has doubled the background noise in many parts of the", x: 20, top: 20),
            line("ocean since the 1960s. Whales that rely on sound to find food and mates", x: 20, top: 44),
            line("now have to call louder and more often, and some have stopped singing", x: 20, top: 68),
            line("altogether when large vessels pass nearby.", x: 20, top: 92)
        ])
        #expect(blocks == [
            "Shipping traffic has doubled the background noise in many parts of the ocean since the 1960s. Whales that rely on sound to find food and mates now have to call louder and more often, and some have stopped singing altogether when large vessels pass nearby."
        ])
    }

    /// 实测：上方有大标题时，Vision 会把段落里某一行的框顶往上多伸一截，框高接近别的行的两倍。
    /// 框高不参与判断，这一行照样能接上。
    @Test func oneInflatedLineBoxDoesNotBreakTheParagraph() {
        var lines = [
            line("Shipping traffic has doubled the background noise in many parts of the", x: 20, top: 20),
            line("ocean since the 1960s. Whales that rely on sound to find food and mates", x: 20, top: 44),
            line("now have to call louder and more often, and some have stopped singing", x: 20, top: 68),
            line("altogether when large vessels pass nearby.", x: 20, top: 92)
        ]
        let tall = lines[2].boundingBox
        let grownBy = 12 / canvas.height
        lines[2] = VisionOCRService.OCRLine(
            text: lines[2].text,
            boundingBox: CGRect(x: tall.minX, y: tall.minY, width: tall.width, height: tall.height + grownBy)
        )
        #expect(group(lines).count == 1)
    }

    @Test func widelySpacedInterfaceRowsStaySeparate() {
        let blocks = group([
            line("Allow notifications on this Mac", x: 24, top: 20, size: 13),
            line("show previews when the screen is unlocked", x: 24, top: 50, size: 13),
            line("notification grouping is automatic", x: 24, top: 80, size: 13)
        ])
        #expect(blocks.count == 3)
    }

    @Test func tightListWithCapitalizedRowsStaysSeparate() {
        let blocks = group([
            line("Allow notifications on this Mac", x: 24, top: 20, size: 13),
            line("Show previews: When Unlocked", x: 24, top: 40, size: 13),
            line("Notification grouping: Automatic", x: 24, top: 60, size: 13)
        ])
        #expect(blocks == [
            "Allow notifications on this Mac",
            "Show previews: When Unlocked",
            "Notification grouping: Automatic"
        ])
    }

    @Test func twoColumnsNeverMergeAcrossTheGutter() {
        let size = CGSize(width: 700, height: 300)
        let blocks = group([
            line("The city council voted on Tuesday to", x: 20, top: 20, size: 14, in: size),
            line("Critics argued that the money would", x: 370, top: 20, size: 14, in: size),
            line("extend the late-night bus service", x: 20, top: 42, size: 14, in: size),
            line("be better spent on repairing roads,", x: 370, top: 42, size: 14, in: size),
            line("for another year.", x: 20, top: 64, size: 14, in: size),
            line("but supporters disagreed.", x: 370, top: 64, size: 14, in: size)
        ], in: size)
        #expect(blocks == [
            "The city council voted on Tuesday to extend the late-night bus service for another year.",
            "Critics argued that the money would be better spent on repairing roads, but supporters disagreed."
        ])
    }

    @Test func sentenceEndingLineStartsANewBlock() {
        let blocks = group([
            line("Downloads are paused while you are on a metered connection.", x: 20, top: 20, size: 11),
            line("tap resume to continue using mobile data, or wait for wi-fi", x: 20, top: 38, size: 11)
        ])
        #expect(blocks.count == 2)
    }

    @Test func chineseLinesJoinWithoutASpace() {
        let blocks = group([
            line("部分用户在连接外接显示器时可能出现画面闪烁，", x: 20, top: 20, size: 14),
            line("建议先断开显示器，完成更新后再重新连接。", x: 20, top: 44, size: 14)
        ])
        #expect(blocks == ["部分用户在连接外接显示器时可能出现画面闪烁，建议先断开显示器，完成更新后再重新连接。"])
    }

    @Test func koreanLinesJoinWithASpace() {
        let blocks = group([
            line("주문하신 상품이 오늘 출고되었으며 배송", x: 20, top: 20, size: 14),
            line("조회는 마이페이지에서 확인하실 수", x: 20, top: 44, size: 14)
        ])
        #expect(blocks == ["주문하신 상품이 오늘 출고되었으며 배송 조회는 마이페이지에서 확인하실 수"])
    }

    @Test func bulletItemsStaySeparateButAWrappedItemIsJoined() {
        let indent = NSAttributedString(string: "• ", attributes: [.font: NSFont.systemFont(ofSize: 14)]).size().width
        let blocks = group([
            line("• Faster startup on older Macs", x: 20, top: 20, size: 14),
            line("• A new dark theme for the editor", x: 20, top: 42, size: 14),
            line("• Fixed a bug where exports could fail", x: 20, top: 64, size: 14),
            line("when the file name contained emoji", x: 20 + indent, top: 86, size: 14)
        ])
        #expect(blocks == [
            "• Faster startup on older Macs",
            "• A new dark theme for the editor",
            "• Fixed a bug where exports could fail when the file name contained emoji"
        ])
    }

    @Test func headingNeverMergesIntoTheBodyBelow() {
        let blocks = group([
            line("getting started with the toolchain", x: 20, top: 20, size: 26, weight: .bold),
            line("swift is a general-purpose programming language that is approachable", x: 20, top: 58),
            line("for newcomers and powerful for experts.", x: 20, top: 82)
        ])
        #expect(blocks.count == 2)
        #expect(blocks.first == "getting started with the toolchain")
    }

    /// 旧实现用「中心点相差不到图片高度的 2%」判同一行：1440pt 高的选区里 2% 是 28.8pt，
    /// 相距 22pt 的两行被当成同一行、再按 x 排序，上下颠倒。
    @Test func tallSelectionKeepsTopToBottomOrder() {
        let size = CGSize(width: 700, height: 1440)
        let blocks = group([
            line("Small caption text at eleven points in size.", x: 24, top: 20, size: 11, in: size),
            line("Footnote text at ten points for comparison.", x: 20, top: 42, size: 11, in: size)
        ], in: size)
        #expect(blocks == [
            "Small caption text at eleven points in size.",
            "Footnote text at ten points for comparison."
        ])
    }

    @Test func hyphenAtTheEndOfALineIsKept() {
        let blocks = group([
            line("This is the most detailed guide to building a self-", x: 20, top: 20),
            line("driving car that we have published so far.", x: 20, top: 44)
        ])
        #expect(blocks == ["This is the most detailed guide to building a self-driving car that we have published so far."])
    }

    @Test func centeredParagraphIsJoined() {
        let first = "thanks for trying the beta, and please keep sending us"
        let second = "feedback through the help menu"
        func centeredX(_ text: String) -> CGFloat {
            300 - NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)]).size().width / 2
        }
        let blocks = group([
            line(first, x: centeredX(first), top: 20),
            line(second, x: centeredX(second), top: 44)
        ])
        #expect(blocks == ["thanks for trying the beta, and please keep sending us feedback through the help menu"])
    }

    @Test func blockKeepsItsLinesTopToBottom() throws {
        let result = OCRParagraphGrouper.group([
            line("altogether when large vessels pass nearby.", x: 20, top: 44),
            line("now have to call louder and more often, and some have stopped singing", x: 20, top: 20)
        ], imageSize: canvas)
        let block = try #require(result.first)
        #expect(result.count == 1)
        #expect(block.lines.map(\.text) == [
            "now have to call louder and more often, and some have stopped singing",
            "altogether when large vessels pass nearby."
        ])
    }
}

@Suite("截图 OCR：源语言")
struct ScreenshotOCRLanguageTests {
    @Test func appLanguageCodesMapToVisionLanguages() {
        #expect(VisionOCRService.visionLanguage(for: "zh-CN") == "zh-Hans")
        #expect(VisionOCRService.visionLanguage(for: "zh-TW") == "zh-Hant")
        #expect(VisionOCRService.visionLanguage(for: "ja") == "ja-JP")
        #expect(VisionOCRService.visionLanguage(for: "pt") == "pt-BR")
        // Vision 的越南语是 vi-VT，写成 vi-VN 会被悄悄忽略。
        #expect(VisionOCRService.visionLanguage(for: "vi") == "vi-VT")
        #expect(VisionOCRService.visionLanguage(for: LanguagePreset.auto.code) == nil)
        #expect(VisionOCRService.visionLanguage(for: "fi") == nil)
    }

    @Test func sourcePickerOffersAutoDetectionAndCommonScripts() {
        let codes = VisionOCRService.selectableSourceLanguages.map(\.code)
        #expect(codes.first == LanguagePreset.auto.code)
        for code in ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "ru"] {
            #expect(codes.contains(code), "缺少 \(code)")
        }
        for code in codes.dropFirst() {
            #expect(VisionOCRService.visionLanguage(for: code) != nil, "\(code) 没有对应的 Vision 语言")
        }
    }

    @Test func onlySmallCapturesAreUpscaled() {
        #expect(VisionOCRService.preprocessScale(pixelWidth: 1000, pixelHeight: 600) == 2)
        #expect(VisionOCRService.preprocessScale(pixelWidth: 2000, pixelHeight: 1200) == 1)
        let fiveK = VisionOCRService.preprocessScale(pixelWidth: 5120, pixelHeight: 2880)
        #expect(fiveK < 1 && fiveK > 0.6)
    }
}

@Suite("截图翻译：逐段判断源语言")
struct ScreenshotTranslationSourceResolverTests {
    private func resolve(
        _ texts: [String],
        source: String = LanguagePreset.auto.code,
        target: String = "zh-CN",
        detected: [String: String] = [:],
        overall: String? = nil
    ) -> [String?] {
        ScreenshotTranslationSourceResolver.resolve(
            blockTexts: texts,
            sourceLanguageCode: source,
            targetLanguageCode: target,
            detectLanguage: { text in text.contains("\n") ? overall : detected[text] }
        )
    }

    @Test func explicitSourceAppliesToEveryBlockWithLetters() {
        #expect(resolve(["Hello world", "2026", "Bonjour"], source: "en") == ["en", nil, "en"])
    }

    @Test func explicitSourceEqualToTargetTranslatesNothing() {
        #expect(resolve(["系统更新", "设置"], source: "zh-CN", target: "zh-CN") == [nil, nil])
    }

    @Test func blocksAlreadyInTheTargetLanguageAreSkipped() {
        let result = resolve(
            ["本次更新修复了若干已知问题", "Install updates automatically"],
            detected: ["本次更新修复了若干已知问题": "zh-CN", "Install updates automatically": "en"],
            overall: "zh-CN"
        )
        #expect(result == [nil, "en"])
    }

    /// 中文页面上的短英文按钮：书写系统对不上整页主语言，只能按拉丁字母猜，交给引擎自动检测。
    @Test func shortLatinLabelOnAChinesePageIsLeftToTheEngineToDetect() {
        #expect(resolve(["本次更新修复了若干已知问题", "Sign in"], detected: ["本次更新修复了若干已知问题": "zh-CN"], overall: "zh-CN") == [nil, LanguagePreset.auto.code])
    }

    @Test func shortLabelFollowsThePageLanguageWhenTheScriptMatches() {
        let result = resolve(
            ["Vous pouvez modifier votre adresse à tout moment", "Annuler"],
            detected: ["Vous pouvez modifier votre adresse à tout moment": "fr"],
            overall: "fr"
        )
        #expect(result == ["fr", "fr"])
    }

    @Test func kanjiOnlyLabelOnAJapanesePageStaysJapanese() {
        #expect(resolve(["お知らせ一覧を表示します", "重要連絡"], detected: ["お知らせ一覧を表示します": "ja"], overall: "ja") == ["ja", "ja"])
    }

    @Test func numbersAndSymbolsAreNeverSentForTranslation() {
        #expect(resolve(["12:30", "$9.99", "→"], overall: "en") == [nil, nil, nil])
    }

    /// 审核发现：整张图只有 Bonjour、目标英语时，识别器弃权、书写系统兜底猜成英语，
    /// 旧逻辑据此判成「不需要翻译」。猜出来的语言不能作为跳过的依据。
    @Test func aGuessThatMatchesTheTargetDoesNotSkipTheBlock() {
        #expect(resolve(["Bonjour"], target: "en") == [LanguagePreset.auto.code])
    }

    /// 审核发现：旧逻辑把没列出的语言一律当拉丁文，阿拉伯文页面上的 Sign in 被当成阿拉伯文。
    @Test func shortLatinLabelOnAnArabicPageIsNotTreatedAsArabic() {
        let arabic = "هذا نص عربي طويل بما يكفي للكشف عن اللغة"
        let result = resolve([arabic, "Sign in"], target: "ar", detected: [arabic: "ar"], overall: "ar")
        #expect(result == [nil, LanguagePreset.auto.code])
    }

    /// 审核发现：书写系统对不上、兜底也认不出时，旧逻辑又把整页主语言塞回来，
    /// 中文页面上的阿拉伯文标签被当成中文、在目标为中文时被跳过。
    @Test func unknownScriptLabelOnAChinesePageIsNotSkipped() {
        let result = resolve(["本次更新修复了若干已知问题", "حفظ"], detected: ["本次更新修复了若干已知问题": "zh-CN"], overall: "zh-CN")
        #expect(result == [nil, LanguagePreset.auto.code])
    }

    @Test func shortLabelInThePageScriptFollowsANonLatinPageLanguage() {
        let arabic = "هذا نص عربي طويل بما يكفي للكشف عن اللغة"
        #expect(resolve([arabic, "حفظ"], target: "en", detected: [arabic: "ar"], overall: "ar") == ["ar", "ar"])
    }

    /// 审核第二轮：认不出的书写系统之间不能互相算匹配，阿拉伯文页面上的希腊文不是阿拉伯文。
    @Test func shortGreekLabelOnAnArabicPageIsNotTreatedAsArabic() {
        let arabic = "هذا نص عربي طويل بما يكفي للكشف عن اللغة"
        let result = resolve([arabic, "Ναι"], target: "ar", detected: [arabic: "ar"], overall: "ar")
        // 希腊文只有希腊语在用，书写系统本身就能确定语言。
        #expect(result == [nil, "el"])
    }

    /// 审核第二轮：简繁要看字形本身，不能拿目标语言当源语言的猜测——
    /// 否则单独一个「设置」在目标为繁体时被判成「不用翻」，永远转不成「設置」。
    @Test func isolatedSimplifiedLabelIsConvertedForATraditionalTarget() {
        #expect(resolve(["设置"], target: "zh-TW") == ["zh-CN"])
    }

    @Test func isolatedTraditionalLabelIsConvertedForASimplifiedTarget() {
        #expect(resolve(["設置"], target: "zh-CN") == ["zh-TW"])
    }

    @Test func traditionalLabelOnASimplifiedPageIsStillConverted() {
        let simplified = "本次更新修复了若干已知问题"
        #expect(resolve([simplified, "設置"], detected: [simplified: "zh-CN"], overall: "zh-CN") == [nil, "zh-TW"])
    }

    /// 简繁同形的字转不转都一样，按目标语言算，不用翻。
    @Test func labelWrittenTheSameInBothVariantsIsSkipped() {
        #expect(resolve(["中文"], target: "zh-TW") == [nil])
        #expect(resolve(["中文"], target: "zh-CN") == [nil])
    }

    @Test func scriptPresenceRecognizesTheScriptsUsedForPageMatching() {
        #expect(TextScriptPresence(in: "Ναι").containsGreek)
        #expect(TextScriptPresence(in: "حفظ").containsArabic)
        #expect(TextScriptPresence(in: "שלום").containsHebrew)
        #expect(TextScriptPresence(in: "สวัสดี").containsThai)
        // 「々」在 CJK 符号区、分解形式的 é 带组合符号，都不能算成「别的书写系统」。
        #expect(!TextScriptPresence(in: "時々").containsUnclassifiedLetters)
        #expect(!TextScriptPresence(in: "caf\u{0065}\u{0301}").containsUnclassifiedLetters)
        #expect(TextScriptPresence(in: "ሰላም").containsUnclassifiedLetters)
    }

    /// 审核第三轮：整页主语言只能当翻译提示，不能单凭它跳过——英文页面上单独的法文 Bonjour 要交给引擎检测。
    @Test func pageLanguageAloneNeverSkipsAShortLabel() {
        let english = "Install updates automatically when they are available"
        let result = resolve([english, "Bonjour"], target: "en", detected: [english: "en"], overall: "en")
        #expect(result == [nil, LanguagePreset.auto.code])
    }

    /// 审核第四轮：混排的短标签不能因为含某种书写系统就整段判成那门语言再跳过。
    @Test func mixedScriptLabelIsNotSkippedBecauseOfOneScript() {
        #expect(resolve(["下载 Save"], target: "zh-CN") == [LanguagePreset.auto.code])
        #expect(resolve(["ダウンロード Save"], target: "ja") == [LanguagePreset.auto.code])
        #expect(resolve(["다운로드 Save"], target: "ko") == [LanguagePreset.auto.code])
    }

    /// 审核第五轮：识别器认出是目标语言，也要先看有没有夹着够分量的外文。中文段落里的一句英文说明
    /// 要翻，而且要按英文翻——交给引擎自动检测的话，它会把整段认成中文、原样返回。
    @Test func detectedTargetLanguageWithSubstantialForeignTextIsStillTranslated() {
        let mixed = "下载方法：Open the App Store and search for Xcode"
        let result = resolve(
            [mixed],
            detected: [mixed: "zh-CN", "Open the App Store and search for Xcode": "en"],
            overall: "zh-CN"
        )
        #expect(result == ["en"])
    }

    @Test func detectedTargetLanguageWithOnlyABrandNameIsSkipped() {
        let text = "打开 Wi-Fi 设置后重新连接网络"
        #expect(resolve([text], detected: [text: "zh-CN"], overall: "zh-CN") == [nil])
    }

    @Test func chineseSentenceInsideAnEnglishParagraphIsTranslatedAsChinese() {
        let mixed = "Please read the notice below: 请在周五之前提交季度报告"
        let result = resolve([mixed], target: "en", detected: [mixed: "en"], overall: "en")
        #expect(result == ["zh-CN"])
    }

    @Test func shortChineseLabelOnAnEnglishPageIsSkippedForAChineseTarget() {
        #expect(resolve(["Install updates automatically", "设置"], detected: ["Install updates automatically": "en"], overall: "en") == ["en", nil])
    }
}

@Suite("截图翻译：按段翻译的调度")
@MainActor
struct ScreenshotBlockTranslatorTests {
    private struct Unsupported: Error {}

    private func job(_ text: String, _ source: String) -> ScreenshotBlockTranslator.Job {
        ScreenshotBlockTranslator.Job(id: UUID(), text: text, sourceLanguageCode: source)
    }

    @Test func onlyAdjacentJobsWithTheSameSourceShareABatch() {
        let batches = ScreenshotBlockTranslator.batches([
            job("Sign in", "en"), job("Forgot password?", "en"),
            job("Annuler", "fr"),
            job("Help", "en")
        ])
        #expect(batches.map { $0.map(\.text) } == [["Sign in", "Forgot password?"], ["Annuler"], ["Help"]])
    }

    @Test func batchesRespectTheJobAndCharacterLimits() {
        let many = (0..<30).map { job("line \($0)", "en") }
        #expect(ScreenshotBlockTranslator.batches(many).map(\.count) == [14, 14, 2])

        let long = String(repeating: "a", count: 1500)
        #expect(ScreenshotBlockTranslator.batches([job(long, "en"), job(long, "en")]).map(\.count) == [1, 1])
    }

    @Test func batchedTranslationIsSplitBackIntoBlocks() async throws {
        let jobs = [job("Sign in", "en"), job("Forgot password?", "en")]
        var requests: [String] = []
        let translator = ScreenshotBlockTranslator(batchesRequests: true) { text, _ in
            requests.append(text)
            return .success(text.components(separatedBy: "\n").map { "译:\($0)" }.joined(separator: "\n"))
        }
        let outcome = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { _ in }))
        #expect(requests == ["Sign in\nForgot password?"])
        #expect(outcome.translations[jobs[0].id] == "译:Sign in")
        #expect(outcome.translations[jobs[1].id] == "译:Forgot password?")
        #expect(outcome.succeeded == 2)
    }

    @Test func batchThatCannotBeSplitBackFallsBackToOneRequestPerBlock() async throws {
        let jobs = [job("Sign in", "en"), job("Forgot password?", "en")]
        var requests: [String] = []
        let translator = ScreenshotBlockTranslator(batchesRequests: true) { text, _ in
            requests.append(text)
            return .success(text.contains("\n") ? "两段被合成了一句" : "译:\(text)")
        }
        let outcome = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { _ in }))
        #expect(requests.count == 3)
        #expect(outcome.translations[jobs[0].id] == "译:Sign in")
        #expect(outcome.translations[jobs[1].id] == "译:Forgot password?")
    }

    /// 审核第三轮：自动检测时各段源语言可能不同。第一段的语言对不被支持，
    /// 不能让后面其他语言的段也跟着不翻；同一门语言的其他段不再重试。
    @Test func languageSpecificFailureDoesNotStopOtherLanguages() async throws {
        let jobs = [job("Ναι", "el"), job("Sign in", "en"), job("Όχι", "el"), job("Cancel", "en")]
        var attempted: [String] = []
        let translator = ScreenshotBlockTranslator(batchesRequests: false) { text, source in
            attempted.append(text)
            return source == "el" ? .failure(AppleTranslationError.unsupportedLanguagePairing) : .success("译:\(text)")
        }
        let outcome = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { _ in }))
        #expect(outcome.translations[jobs[1].id] == "译:Sign in")
        #expect(outcome.translations[jobs[3].id] == "译:Cancel")
        #expect(outcome.translations[jobs[0].id] == "Ναι")
        #expect(outcome.translations[jobs[2].id] == "Όχι")
        #expect(attempted == ["Ναι", "Sign in", "Cancel"])
        #expect(outcome.succeeded == 2)
        #expect(!outcome.stoppedEarly)
    }

    /// 审核第四轮：只有明确的「语言对不可用」才熔断这门语言；一次普通失败（空响应、个别请求 400）
    /// 不能让同语言的其他段都不翻。
    @Test func aRequestSpecificFailureDoesNotSuppressTheLanguage() async throws {
        let jobs = [job("Sign in", "en"), job("Cancel", "en")]
        let translator = ScreenshotBlockTranslator(batchesRequests: false) { text, _ in
            text == "Sign in" ? .failure(HTTPClient.HTTPError.badStatus(code: 400, body: "")) : .success("译:\(text)")
        }
        let outcome = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { _ in }))
        #expect(outcome.translations[jobs[1].id] == "译:Cancel")
        #expect(outcome.succeeded == 1)
    }

    @Test func autoDetectedBlocksAreNotShortCircuitedByOneFailure() async throws {
        let jobs = [job("?!", "auto"), job("Sign in", "auto")]
        let translator = ScreenshotBlockTranslator(batchesRequests: false) { text, _ in
            text == "?!" ? .failure(Unsupported()) : .success("译:\(text)")
        }
        let outcome = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { _ in }))
        #expect(outcome.translations[jobs[1].id] == "译:Sign in")
        #expect(outcome.succeeded == 1)
    }

    @Test func requestWideFailureStopsImmediately() async throws {
        let jobs = [job("Install updates automatically", "en"), job("Vous pouvez modifier votre adresse", "fr")]
        var attempts = 0
        let translator = ScreenshotBlockTranslator(batchesRequests: true) { _, _ in
            attempts += 1
            return .failure(URLError(.notConnectedToInternet))
        }
        let outcome = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { _ in }))
        #expect(attempts == 1)
        #expect(outcome.stoppedEarly)
        #expect(outcome.succeeded == 0)
        #expect(outcome.translations[jobs[1].id] == "Vous pouvez modifier votre adresse")
    }

    @Test func requestWideErrorsAreRecognized() {
        #expect(ScreenshotBlockTranslator.isRequestWide(URLError(.timedOut)))
        #expect(ScreenshotBlockTranslator.isRequestWide(CancellationError()))
        #expect(ScreenshotBlockTranslator.isRequestWide(HTTPClient.HTTPError.badStatus(code: 401, body: "")))
        #expect(ScreenshotBlockTranslator.isRequestWide(HTTPClient.HTTPError.badStatus(code: 429, body: "")))
        #expect(ScreenshotBlockTranslator.isRequestWide(HTTPClient.HTTPError.badStatus(code: 503, body: "")))
        #expect(!ScreenshotBlockTranslator.isRequestWide(HTTPClient.HTTPError.badStatus(code: 400, body: "")))
        #expect(!ScreenshotBlockTranslator.isRequestWide(Unsupported()))
    }

    @Test func onlyUnavailableLanguagePairsSuppressALanguage() {
        #expect(ScreenshotBlockTranslator.isLanguagePairUnavailable(AppleTranslationError.unsupportedLanguagePairing))
        #expect(ScreenshotBlockTranslator.isLanguagePairUnavailable(AppleTranslationError.unsupportedLanguagePair(source: "希腊语", target: "中文")))
        #expect(!ScreenshotBlockTranslator.isLanguagePairUnavailable(AppleTranslationError.translationFailed("x")))
        #expect(!ScreenshotBlockTranslator.isLanguagePairUnavailable(AppleTranslationError.unableToIdentifyLanguage))
        #expect(!ScreenshotBlockTranslator.isLanguagePairUnavailable(HTTPClient.HTTPError.badStatus(code: 400, body: "")))
        #expect(!ScreenshotBlockTranslator.isLanguagePairUnavailable(Unsupported()))
    }

    /// 审核第五轮：OpenAI SDK 的 HTTP 失败也要按鉴权 / 限流 / 服务端错误归为整体性失败。
    @Test func openAISDKFailuresAreClassifiedLikeHTTPFailures() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/responses"))
        func status(_ code: Int) throws -> OpenAIError {
            .statusError(response: try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)), statusCode: code)
        }
        #expect(ScreenshotBlockTranslator.isRequestWide(try status(401)))
        #expect(ScreenshotBlockTranslator.isRequestWide(try status(503)))
        #expect(!ScreenshotBlockTranslator.isRequestWide(try status(400)))

        let decoder = JSONDecoder()
        let invalidKey = try decoder.decode(APIErrorResponse.self, from: Data(#"{"error":{"message":"Incorrect API key","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8))
        let badInput = try decoder.decode(APIErrorResponse.self, from: Data(#"{"error":{"message":"bad input","type":"invalid_request_error","code":"invalid_value"}}"#.utf8))
        let geminiOverloaded = try decoder.decode(GeminiAPIErrorResponse.self, from: Data(#"{"error":{"code":503,"message":"overloaded","status":"UNAVAILABLE"}}"#.utf8))
        #expect(ScreenshotBlockTranslator.isRequestWide(invalidKey))
        #expect(!ScreenshotBlockTranslator.isRequestWide(badInput))
        #expect(ScreenshotBlockTranslator.isRequestWide(geminiOverloaded))
    }

    @Test func progressIsReportedAfterEachBatch() async throws {
        let jobs = [job("Sign in", "en"), job("Annuler", "fr")]
        var reports: [Int] = []
        let translator = ScreenshotBlockTranslator(batchesRequests: true) { text, _ in .success("译:\(text)") }
        _ = try #require(await translator.run(jobs, shouldContinue: { true }, onProgress: { reports.append($0.count) }))
        #expect(reports == [1, 2])
    }

    @Test func abandonsTheRunWhenTheSelectionChanges() async {
        var keepGoing = true
        let translator = ScreenshotBlockTranslator(batchesRequests: false) { text, _ in
            keepGoing = false
            return .success(text)
        }
        let outcome = await translator.run(
            [job("Install updates automatically", "en"), job("Remove this device", "en")],
            shouldContinue: { keepGoing },
            onProgress: { _ in }
        )
        #expect(outcome == nil)
    }
}

/// 跑真实的 Vision。标准答案就是画进去的字，所以断言尽量只看关键片段。
@Suite("截图 OCR：真实识别回归")
@MainActor
struct ScreenshotOCRRecognitionTests {
    private func recognize(_ texts: [SyntheticText], width: CGFloat = 600, height: CGFloat = 200, language: String = LanguagePreset.auto.code) async -> [VisionOCRService.OCRBlock] {
        let image = SyntheticScreenshot(name: "", width: width, height: height, texts: texts).render()
        return await VisionOCRService.recognizeBlocks(from: image, languageCode: language)
    }

    /// 旧的西语「修正」按子串匹配触发词，英文里的 trusted 含 "usted"，
    /// 触发后把所有 I 开头的行改成「¿nstall…」「¿f a device…」。
    @Test func englishLinesStartingWithIKeepTheirI() async {
        let blocks = await recognize(
            [SyntheticText(text: "Trusted devices", x: 24, y: 14, size: 18, weight: .semibold)]
            + SyntheticScreenshot.lines(["Install updates automatically", "If a device is lost, remove it from this list."], top: 52, size: 13, lineHeight: 30),
            language: "en"
        )
        let text = blocks.map(\.text).joined(separator: "\n")
        #expect(text.contains("Install updates automatically"))
        #expect(text.contains("If a device is lost"))
        #expect(!text.contains("¿"))
    }

    @Test func spanishLinesStartingWithIKeepTheirI() async {
        let blocks = await recognize(
            SyntheticScreenshot.lines(["Iniciar sesión", "Importante: revise su correo"], top: 20, size: 15, lineHeight: 34),
            language: "es"
        )
        let text = blocks.map(\.text).joined(separator: "\n")
        #expect(text.contains("Iniciar sesión"))
        #expect(text.contains("Importante"))
        #expect(!text.contains("¿"))
    }

    /// 旧的俄语「修正」会把拉丁单词换成形近的西里尔字母：Apple Music на iPhone → Аррле Миsис на Ирhопе。
    @Test func russianTextKeepsItsLatinWords() async {
        let blocks = await recognize(
            SyntheticScreenshot.lines(["Скачайте Apple Music на iPhone", "Нажмите OK, затем Cancel"], top: 20, size: 15, lineHeight: 34),
            language: "ru"
        )
        let text = blocks.map(\.text).joined(separator: "\n")
        #expect(text.contains("Apple Music"))
        #expect(text.contains("iPhone"))
        #expect(text.contains("Cancel"))
    }

    /// 以前源语言只能选英 / 俄 / 西，中文被当成英文去认，整段变成「2026 € 38」。
    @Test func chineseIsRecognizedWithAutoDetection() async {
        let blocks = await recognize(
            [SyntheticText(text: "系统更新说明", x: 24, y: 16, size: 20, weight: .bold)]
            + SyntheticScreenshot.lines(["本次更新修复了若干已知问题，并提升了电池续航表现。"], top: 58, size: 14, lineHeight: 26)
        )
        let text = blocks.map(\.text).joined()
        #expect(text.contains("系统更新说明"))
        #expect(text.contains("电池续航"))
    }

    @Test func japaneseIsRecognizedWithAutoDetection() async {
        let blocks = await recognize(
            [SyntheticText(text: "お知らせ", x: 24, y: 16, size: 20, weight: .bold)]
            + SyntheticScreenshot.lines(["明日の午前二時から四時まで、システムのメンテナンスを行います。"], top: 58, size: 14, lineHeight: 26)
        )
        let text = blocks.map(\.text).joined()
        #expect(text.contains("お知らせ"))
        #expect(text.contains("メンテナンス"))
    }

    /// 手动指定日语时必须关掉自动识别：开着的话，纯汉字的日文照样被认成繁体（閲 → 閱）。
    @Test func explicitJapaneseKeepsKanjiOnlyTextJapanese() async {
        let blocks = await recognize(
            SyntheticScreenshot.lines(["明日午前、定期点検実施。", "作業中、閲覧不可。"], top: 20, size: 14, lineHeight: 30),
            language: "ja"
        )
        let text = blocks.map(\.text).joined()
        #expect(text.contains("閲覧"))
        #expect(!text.contains("閱"))
    }

    @Test func wrappedParagraphIsRecognizedAsOneBlock() async {
        let blocks = await recognize(
            [SyntheticText(text: "Why the Ocean Is Getting Louder", x: 24, y: 16, size: 26, weight: .bold)]
            + SyntheticScreenshot.lines([
                "Shipping traffic has doubled the background noise in many parts of the",
                "ocean since the 1960s. Whales that rely on sound to find food and mates",
                "now have to call louder and more often, and some have stopped singing",
                "altogether when large vessels pass nearby."
            ], top: 66, size: 15, lineHeight: 24),
            width: 640,
            height: 190
        )
        #expect(blocks.count == 2)
        #expect(blocks.last?.lines.count == 4)
        #expect(blocks.last?.text.contains("many parts of the ocean since the 1960s") == true)
    }

    /// 旧的去重会把同一排里相同的两个词删掉一个，那个位置就没有译文。
    @Test func identicalLabelsOnOneRowAreBothKept() async {
        let blocks = await recognize([
            SyntheticText(text: "Settings", x: 40, y: 40, size: 15),
            SyntheticText(text: "Settings", x: 360, y: 40, size: 15)
        ], height: 120)
        #expect(blocks.map(\.text) == ["Settings", "Settings"])
    }

    @Test func benchmarkScreenshotsAreRecognizedAccurately() async {
        var report: [String] = []
        for screenshot in SyntheticScreenshot.benchmark {
            let blocks = await VisionOCRService.recognizeBlocks(
                from: screenshot.render(),
                languageCode: LanguagePreset.auto.code
            )
            let rate = characterErrorRate(expected: screenshot.groundTruth, actual: blocks.map(\.text).joined(separator: "\n"))
            report.append("\(screenshot.name) \(String(format: "%.1f%%", rate * 100))")
            #expect(rate <= 0.02, "\(screenshot.name) 字符错误率 \(rate)")
        }
        print("截图 OCR 基准：" + report.joined(separator: "，"))
    }
}
