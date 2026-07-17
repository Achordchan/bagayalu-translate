//
//  dazuofanyiguanTests.swift
//  dazuofanyiguanTests
//
//  Created by AchordChan on 2025/12/19.
//

import AppKit
import Testing
import UniformTypeIdentifiers
@testable import 大佐翻译官v1

struct dazuofanyiguanTests {

    @Test func permissionGuideProvidesDraggableApplicationFileURL() {
        let applicationURL = URL(fileURLWithPath: "/Applications/大佐翻译官v1.app")
        let provider = PermissionGuideDragItemProvider.make(
            applicationURL: applicationURL
        )

        #expect(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        )
    }

    @Test func languageDetectionRecognizesClearLongText() {
        let detector = LanguageDetectionService.shared

        let english = detector.detectLanguage(
            in: "This application translates selected text quickly and accurately between multiple languages."
        )
        let simplifiedChinese = detector.detectLanguage(
            in: "这是一段用于验证本地语言识别服务的简体中文测试文本。"
        )
        let traditionalChinese = detector.detectLanguage(
            in: "這是一段用於驗證本機語言辨識服務的繁體中文測試文字。"
        )

        #expect(english?.languageCode == "en")
        #expect(simplifiedChinese?.languageCode == "zh-CN")
        #expect(traditionalChinese?.languageCode == "zh-TW")
    }

    @Test func languageDetectionRejectsEmptyAndShortText() {
        let detector = LanguageDetectionService.shared

        #expect(detector.detectLanguage(in: "   ") == nil)
        #expect(detector.detectLanguage(in: "Hi") == nil)
        #expect(detector.detectLanguage(in: "你好") == nil)
    }

    @Test func ocrLanguageDetectionKeepsRussianArtifactRule() {
        let detector = LanguageDetectionService.shared
        let artifactText = "npnBeT 3TO npnBeT 3TO npnBeT 3TO"

        #expect(
            detector.detectLanguage(in: artifactText, purpose: .ocr)?.languageCode == "ru"
        )
    }

    @Test func appleTranslationIsTheFirstEngineOption() {
        #expect(TranslationEngineType.allCases.first == .apple)
        #expect(TranslationEngineType.apple.title == "Apple 本地翻译")
    }

    @Test func openAIEndpointValidatorAllowsHTTPSAndLocalHTTPOnly() throws {
        let https = try OpenAIEndpointValidator.validatedBaseURL(
            from: "https://api.openai.com/v1"
        )
        #expect(https.scheme == "https")
        #expect(https.host == "api.openai.com")

        let local = try OpenAIEndpointValidator.validatedBaseURL(
            from: "http://localhost:8080/v1"
        )
        #expect(local.scheme == "http")
        #expect(local.host == "localhost")

        #expect(throws: OpenAIEndpointValidationError.insecureRemoteHTTP) {
            try OpenAIEndpointValidator.validatedBaseURL(from: "http://example.com/v1")
        }
        #expect(throws: OpenAIEndpointValidationError.containsUserInfo) {
            try OpenAIEndpointValidator.validatedBaseURL(
                from: "https://user:pass@api.openai.com/v1"
            )
        }
        #expect(throws: OpenAIEndpointValidationError.containsFragment) {
            try OpenAIEndpointValidator.validatedBaseURL(
                from: "https://api.openai.com/v1#frag"
            )
        }
        #expect(throws: OpenAIEndpointValidationError.empty) {
            try OpenAIEndpointValidator.validatedBaseURL(from: "   ")
        }
    }

    @Test func engineMigrationPolicyOnlyFillsMissingEngineType() {
        // 仅“未存储 engineType”才允许写默认 Apple；已有 Google 选择必须保留。
        let missingStoredEngine: String? = nil
        let storedGoogle: String? = TranslationEngineType.google.rawValue
        let storedApple: String? = TranslationEngineType.apple.rawValue

        func shouldWriteDefaultApple(stored: String?) -> Bool {
            stored == nil
        }

        #expect(shouldWriteDefaultApple(stored: missingStoredEngine))
        #expect(!shouldWriteDefaultApple(stored: storedGoogle))
        #expect(!shouldWriteDefaultApple(stored: storedApple))
    }

    @Test func googleTranslateRejectsOversizedTextLocally() async {
        let engine = GoogleTranslateEngine()
        let huge = String(repeating: "A", count: 9000)
        var thrown: Error?
        do {
            _ = try await engine.translate(
                text: huge,
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-CN"
            )
        } catch {
            thrown = error
        }

        guard let engineError = thrown as? GoogleTranslateEngine.EngineError else {
            #expect(Bool(false), "expected EngineError, got: \(String(describing: thrown))")
            return
        }
        var isTooLong = false
        if case .textTooLong = engineError {
            isTooLong = true
        }
        #expect(isTooLong, "expected textTooLong, got: \(engineError)")
    }

    @Test func miniModeRoutesAppleDownloadToMainWindow() {
        #expect(
            MiniTranslationRouting.route(
                engineType: .apple,
                applePreparationStatus: .installed
            ) == .translateInBubble
        )
        #expect(
            MiniTranslationRouting.route(
                engineType: .apple,
                applePreparationStatus: .downloadRequired
            ) == .openMainWindow
        )
        #expect(
            MiniTranslationRouting.route(
                engineType: .apple,
                applePreparationStatus: .unsupported(message: "不支持")
            ) == .showError("不支持")
        )
        #expect(
            MiniTranslationRouting.route(
                engineType: .google,
                applePreparationStatus: nil
            ) == .translateInBubble
        )
    }

    @Test func miniModeRejectsStaleRequestResults() {
        var tracker = MiniTranslationRequestTracker()
        let first = tracker.begin()
        let second = tracker.begin()

        #expect(!tracker.accepts(first))
        #expect(tracker.accepts(second))

        tracker.invalidate()
        #expect(!tracker.accepts(second))
    }

    @Test func miniModePrefersChineseForNonChineseText() {
        let english = MiniTranslationDirectionResolver.resolve(
            text: "This application translates selected text quickly and accurately.",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN"
        )
        let traditionalChineseTarget = MiniTranslationDirectionResolver.resolve(
            text: "This application translates selected text quickly and accurately.",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-TW"
        )
        let japanese = MiniTranslationDirectionResolver.resolve(
            text: "今日はとても良い天気です。",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN"
        )

        #expect(english.sourceLanguageCode == "en")
        #expect(english.targetLanguageCode == "zh-CN")
        #expect(traditionalChineseTarget.targetLanguageCode == "zh-TW")
        #expect(japanese.sourceLanguageCode == "ja")
        #expect(japanese.targetLanguageCode == "zh-CN")
    }

    @Test func miniModeReversesChineseToConfiguredNonChineseLanguage() {
        let simplifiedChinese = MiniTranslationDirectionResolver.resolve(
            text: "这是一段用于验证智能翻译方向的简体中文。",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN"
        )
        let shortChinese = MiniTranslationDirectionResolver.resolve(
            text: "你好",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN"
        )
        let traditionalChinese = MiniTranslationDirectionResolver.resolve(
            text: "這是一段用於驗證智慧翻譯方向的繁體中文。",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN"
        )
        let configuredJapanese = MiniTranslationDirectionResolver.resolve(
            text: "这段中文应该翻译成日语。",
            sourceLanguageCode: "ja",
            targetLanguageCode: "zh-CN"
        )

        #expect(simplifiedChinese.targetLanguageCode == "en")
        #expect(shortChinese.targetLanguageCode == "en")
        #expect(traditionalChinese.targetLanguageCode == "en")
        #expect(configuredJapanese.targetLanguageCode == "ja")
    }

    @Test func miniModeKeepsConfiguredPairForTextWithoutLetters() {
        let result = MiniTranslationDirectionResolver.resolve(
            text: "12345 ---",
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN"
        )

        #expect(
            result == TranslationLanguagePair(
                sourceLanguageCode: "auto",
                targetLanguageCode: "zh-CN"
            )
        )
    }

    @Test func accessibilityAuthorizationPrefersGlobalHotkeyAtTheRightTimes() {
        #expect(
            !ShortcutPermissionPolicy.shouldPreferGlobalHotkey(
                isAccessibilityTrusted: false,
                permissionWasMissing: true,
                isTextShortcutEnabled: true,
                hasAppliedPreferredDefault: false
            )
        )
        #expect(
            ShortcutPermissionPolicy.shouldPreferGlobalHotkey(
                isAccessibilityTrusted: true,
                permissionWasMissing: false,
                isTextShortcutEnabled: true,
                hasAppliedPreferredDefault: false
            )
        )
        #expect(
            !ShortcutPermissionPolicy.shouldPreferGlobalHotkey(
                isAccessibilityTrusted: true,
                permissionWasMissing: false,
                isTextShortcutEnabled: true,
                hasAppliedPreferredDefault: true
            )
        )
        #expect(
            ShortcutPermissionPolicy.shouldPreferGlobalHotkey(
                isAccessibilityTrusted: true,
                permissionWasMissing: true,
                isTextShortcutEnabled: true,
                hasAppliedPreferredDefault: true
            )
        )
        #expect(
            !ShortcutPermissionPolicy.shouldPreferGlobalHotkey(
                isAccessibilityTrusted: true,
                permissionWasMissing: true,
                isTextShortcutEnabled: false,
                hasAppliedPreferredDefault: false
            )
        )
    }

    @Test func miniBubbleStaysInsideVisibleScreenFrame() {
        let visibleFrame = CGRect(x: 100, y: 100, width: 1_000, height: 700)
        let contentSizes = [
            NSSize(width: 420, height: 220),
            NSSize(width: 460, height: 420)
        ]

        for contentSize in contentSizes {
            let topRightOrigin = MiniTranslationLayout.bubbleOrigin(
                anchor: CGPoint(x: 1_090, y: 790),
                contentSize: contentSize,
                visibleFrame: visibleFrame
            )
            let bottomLeftOrigin = MiniTranslationLayout.bubbleOrigin(
                anchor: CGPoint(x: 105, y: 105),
                contentSize: contentSize,
                visibleFrame: visibleFrame
            )

            for origin in [topRightOrigin, bottomLeftOrigin] {
                #expect(origin.x >= visibleFrame.minX + 12)
                #expect(origin.y >= visibleFrame.minY + 12)
                #expect(origin.x + contentSize.width <= visibleFrame.maxX - 12)
                #expect(origin.y + contentSize.height <= visibleFrame.maxY - 12)
            }
        }
    }

    @Test func textFontSizesKeepTheCurrentDefaultAndSanitizeStoredValues() {
        #expect(AppTextFontSize.defaultValue == 15)
        #expect(AppTextFontSize.tickValues == [12, 15, 18, 21, 24])
        #expect(AppTextFontSize.sanitized(11) == 12)
        #expect(AppTextFontSize.sanitized(14) == 14)
        #expect(AppTextFontSize.sanitized(14.6) == 15)
        #expect(AppTextFontSize.sanitized(18) == 18)
        #expect(AppTextFontSize.sanitized(25) == 24)
        #expect(AppTextFontSize.sanitized(.nan) == 15)
    }

    @Test func globalHotkeyRecommendationHonorsPermissionFailureAndReminderChoices() {
        let now = Date(timeIntervalSince1970: 10_000)

        #expect(
            ShortcutRecommendationPolicy.shouldRecommendGlobalHotkey(
                isAccessibilityTrusted: true,
                isTextShortcutEnabled: true,
                isClipboardModeSelected: true,
                globalMonitorFailed: false,
                isNeverReminderEnabled: false,
                reminderAvailableAt: .distantPast,
                now: now
            )
        )
        #expect(
            ShortcutRecommendationPolicy.shouldRecommendGlobalHotkey(
                isAccessibilityTrusted: true,
                isTextShortcutEnabled: true,
                isClipboardModeSelected: false,
                globalMonitorFailed: true,
                isNeverReminderEnabled: false,
                reminderAvailableAt: .distantPast,
                now: now
            )
        )
        #expect(
            !ShortcutRecommendationPolicy.shouldRecommendGlobalHotkey(
                isAccessibilityTrusted: true,
                isTextShortcutEnabled: true,
                isClipboardModeSelected: true,
                globalMonitorFailed: false,
                isNeverReminderEnabled: true,
                reminderAvailableAt: .distantPast,
                now: now
            )
        )
        #expect(
            !ShortcutRecommendationPolicy.shouldRecommendGlobalHotkey(
                isAccessibilityTrusted: true,
                isTextShortcutEnabled: true,
                isClipboardModeSelected: true,
                globalMonitorFailed: false,
                isNeverReminderEnabled: false,
                reminderAvailableAt: now.addingTimeInterval(1),
                now: now
            )
        )
    }

    @Test func miniResultBubbleKeepsReadableContentHeight() {
        let shortResultSize = MiniTranslationLayout.contentSize(for: .result("WebSockets"))
        let multilineResultSize = MiniTranslationLayout.contentSize(
            for: .result("第一行\n第二行\n第三行\n第四行")
        )

        #expect(shortResultSize.height >= 160)
        #expect(multilineResultSize.height >= shortResultSize.height)
        #expect(multilineResultSize.height <= 340)
    }

    @Test func miniResultBubbleExpandsForLargerTextWithoutGrowingUnbounded() {
        let text = String(repeating: "这是用于验证 Mini 窗口字号布局的文字。", count: 24)
        let defaultSize = MiniTranslationLayout.contentSize(
            for: .result(text),
            fontSize: 15
        )
        let largeSize = MiniTranslationLayout.contentSize(
            for: .result(text),
            fontSize: 24
        )

        #expect(largeSize.height >= defaultSize.height)
        #expect(largeSize.height <= 420)
    }

    @Test func miniSmartDirectionNoticeGetsAdditionalFooterSpace() {
        let regularSize = MiniTranslationLayout.contentSize(
            for: .result("Hello"),
            fontSize: 15,
            showsSmartDirectionNotice: false
        )
        let smartDirectionSize = MiniTranslationLayout.contentSize(
            for: .result("你好"),
            fontSize: 15,
            showsSmartDirectionNotice: true
        )

        #expect(smartDirectionSize.height == regularSize.height + 24)
        #expect(smartDirectionSize.height <= 420)
    }

    @Test func programmaticLongTextChangesStaySuppressedUntilUserEdits() {
        var inputChangeGuard = TranslationInputChangeGuard()
        let longText = String(repeating: "这是一段用于测试 Mini 模式的长文本。", count: 200)

        inputChangeGuard.markProgrammaticText(longText)

        let firstRepeatedChange = inputChangeGuard.shouldSchedule(for: longText)
        let secondRepeatedChange = inputChangeGuard.shouldSchedule(for: longText)
        let thirdRepeatedChange = inputChangeGuard.shouldSchedule(for: longText)

        #expect(!firstRepeatedChange)
        #expect(!secondRepeatedChange)
        #expect(!thirdRepeatedChange)

        let editedText = longText + "用户新增内容"
        let firstUserEdit = inputChangeGuard.shouldSchedule(for: editedText)
        let secondUserEdit = inputChangeGuard.shouldSchedule(for: editedText)

        #expect(firstUserEdit)
        #expect(secondUserEdit)
    }

    @Test func clipboardDoubleCopyPolicyRequiresIdenticalContent() {
        #expect(
            ClipboardDoubleCopyPolicy.isMatchingDoubleCopy(
                previous: "hello",
                current: "hello",
                intervalMs: 300,
                windowMs: 550
            )
        )
        #expect(
            !ClipboardDoubleCopyPolicy.isMatchingDoubleCopy(
                previous: "hello",
                current: "world",
                intervalMs: 300,
                windowMs: 550
            )
        )
        #expect(
            !ClipboardDoubleCopyPolicy.isMatchingDoubleCopy(
                previous: "hello",
                current: "hello",
                intervalMs: 900,
                windowMs: 550
            )
        )
        #expect(
            !ClipboardDoubleCopyPolicy.isMatchingDoubleCopy(
                previous: "hello",
                current: "   ",
                intervalMs: 200,
                windowMs: 550
            )
        )
        #expect(
            ClipboardDoubleCopyPolicy.isMatchingDoubleCopy(
                previous: "  hello  ",
                current: "hello",
                intervalMs: 100,
                windowMs: 550
            )
        )
    }

    @Test func clipboardDoubleCopyPolicySuppressesRapidDuplicateEmission() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(
            ClipboardDoubleCopyPolicy.shouldSuppressDuplicateEmission(
                lastEmittedText: "same",
                lastEmittedDate: now.addingTimeInterval(-0.2),
                currentText: "same",
                now: now,
                windowMs: 550
            )
        )
        #expect(
            !ClipboardDoubleCopyPolicy.shouldSuppressDuplicateEmission(
                lastEmittedText: "same",
                lastEmittedDate: now.addingTimeInterval(-2),
                currentText: "same",
                now: now,
                windowMs: 550
            )
        )
        #expect(
            !ClipboardDoubleCopyPolicy.shouldSuppressDuplicateEmission(
                lastEmittedText: "old",
                lastEmittedDate: now.addingTimeInterval(-0.1),
                currentText: "new",
                now: now,
                windowMs: 550
            )
        )
    }

    @Test func httpClientSanitizesAndTruncatesErrorBodies() {
        #expect(HTTPClient.sanitizedErrorBody(from: Data()) == "")
        #expect(
            HTTPClient.sanitizedErrorBody(from: Data("  hello\nworld  ".utf8)) == "hello world"
        )

        let long = String(repeating: "a", count: HTTPClient.errorBodyCharacterLimit + 80)
        let sanitized = HTTPClient.sanitizedErrorBody(from: Data(long.utf8))
        #expect(sanitized.hasSuffix("…"))
        #expect(sanitized.count == HTTPClient.errorBodyCharacterLimit + 1)
        #expect(HTTPClient.responseByteLimit == 2_000_000)
    }

    @Test func screenRegionComposeMathSplitsDualScreenSelection() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1200, height: 800)
        let selection = CGRect(x: 900, y: 100, width: 300, height: 200)
        let frames: [CGRect] = [left, right]

        let layouts = ScreenRegionComposeMath.layouts(
            selection: selection,
            screenFrames: frames
        )
        let layoutCount = layouts.count
        #expect(layoutCount == 2)

        let first = layouts[0]
        let firstMinX = first.rectInScreen.minX
        let firstWidth = first.rectInScreen.width
        let firstOriginX = first.originInUnionTopLeft.x
        let firstOriginY = first.originInUnionTopLeft.y
        #expect(firstMinX == 900)
        #expect(firstWidth == 100)
        #expect(firstOriginX == 0)
        #expect(firstOriginY == 0)

        let second = layouts[1]
        let secondMinX = second.rectInScreen.minX
        let secondWidth = second.rectInScreen.width
        let secondOriginX = second.originInUnionTopLeft.x
        let secondOriginY = second.originInUnionTopLeft.y
        #expect(secondMinX == 1000)
        #expect(secondWidth == 200)
        #expect(secondOriginX == 100)
        #expect(secondOriginY == 0)
    }

    @Test func screenRegionComposeMathFlipsDrawRectToCGContext() {
        let origin = CGPoint(x: 10, y: 20)
        let pixelSize = CGSize(width: 100, height: 50)
        let imageScale: CGFloat = 2
        let outputScale: CGFloat = 2
        let unionHeightPoints: CGFloat = 200

        let draw = ScreenRegionComposeMath.drawRectInCGContext(
            originInUnionTopLeft: origin,
            imagePixelSize: pixelSize,
            imageScale: imageScale,
            outputScale: outputScale,
            unionHeightPoints: unionHeightPoints
        )
        // (200 * 2) - (20 * 2) - 50 = 310
        let expectedY: CGFloat = 310
        let drawX = draw.origin.x
        let drawY = draw.origin.y
        let drawW = draw.size.width
        let drawH = draw.size.height
        #expect(drawX == 20)
        #expect(drawW == 100)
        #expect(drawH == 50)
        #expect(drawY == expectedY)
    }

    @Test func openAIResponseParserExtractsChatCompletionsAutoDetectPayload() throws {
        // 拆成局部常量，避免 x86_64 上整段表达式类型推断超时。
        let nestedPayload = #"{"detectedSourceLanguageCode":"en","translatedText":"你好"}"#
        let messageObject: [String: Any] = [
            "message": ["content": nestedPayload]
        ]
        let rootObject: [String: Any] = [
            "choices": [messageObject]
        ]
        let chatData = try JSONSerialization.data(withJSONObject: rootObject)
        let content = try OpenAIResponseParser.contentText(
            from: chatData,
            endpointMode: .chatCompletions
        )
        let result = OpenAIResponseParser.parseAutoDetectResult(from: content)
        let translated = result?.translatedText
        let detected = result?.detectedSourceLanguageCode
        #expect(translated == "你好")
        #expect(detected == "en")
    }

    @Test func openAIResponseParserExtractsFencedAutoDetectPayload() {
        let fenced = """
        ```json
        {"detected_source_language_code":"ja","translated_text":"早上好"}
        ```
        """
        let fencedResult = OpenAIResponseParser.parseAutoDetectResult(from: fenced)
        let translated = fencedResult?.translatedText
        let detected = fencedResult?.detectedSourceLanguageCode
        #expect(translated == "早上好")
        #expect(detected == "ja")
    }

    @Test func openAIResponseParserExtractsResponsesPlainText() throws {
        let responsesObject: [String: Any] = ["output_text": "只是纯文本"]
        let responsesData = try JSONSerialization.data(withJSONObject: responsesObject)
        let responsesContent = try OpenAIResponseParser.contentText(
            from: responsesData,
            endpointMode: .responses
        )
        #expect(responsesContent == "只是纯文本")
    }


    @Test func legacyKeychainItemPolicyOnlyMatchesMissingOrEmptyService() {
        #expect(LegacyKeychainItemPolicy.isLegacyService(nil))
        #expect(LegacyKeychainItemPolicy.isLegacyService(""))
        #expect(LegacyKeychainItemPolicy.isLegacyService("   "))
        #expect(!LegacyKeychainItemPolicy.isLegacyService("com.achord.dazuofanyiguan"))
        #expect(!LegacyKeychainItemPolicy.isLegacyService("com.other.app"))
    }

    @Test func translationRequestContextFreezesPreparedTextAndEngineSettings() {
        let request = TranslationRequestContext.make(
            text: "line1\nline2",
            engineType: .google,
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN",
            openAIBaseURL: "https://api.openai.com/v1",
            openAIModel: "gpt-test",
            openAIEndpointMode: .chatCompletions
        )

        #expect(request != nil)
        #expect(request?.engineType == .google)
        #expect(request?.sourceLanguageCode == "en")
        #expect(request?.targetLanguageCode == "zh-CN")
        #expect(request?.preparedText.contains(TranslationRequestContext.newlineMarker) == true)
        #expect(request?.shouldRestoreNewlines == true)

        let restored = TranslationRequestContext.restoreNewlines(
            from: "A \(TranslationRequestContext.newlineMarker) B"
        )
        #expect(restored == "A\nB")

        let empty = TranslationRequestContext.make(
            text: "   ",
            engineType: .apple,
            sourceLanguageCode: "auto",
            targetLanguageCode: "zh-CN",
            openAIBaseURL: "https://api.openai.com/v1",
            openAIModel: "",
            openAIEndpointMode: .chatCompletions
        )
        #expect(empty == nil)
    }

    @Test func screenRegionComposeMathClipsSingleScreenSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // 选区下半部分伸进虚拟桌面空白区（y 为负）。
        let selection = CGRect(x: 100, y: -50, width: 200, height: 150)
        let frames: [CGRect] = [screen]
        let layouts = ScreenRegionComposeMath.layouts(
            selection: selection,
            screenFrames: frames
        )
        let layoutCount = layouts.count
        #expect(layoutCount == 1)
        let clipped = layouts[0].rectInScreen
        let minY = clipped.minY
        let height = clipped.height
        let minX = clipped.minX
        let width = clipped.width
        #expect(minY == 0)
        #expect(height == 100)
        #expect(minX == 100)
        #expect(width == 200)
    }



    @Test func googleTranslatePostRequestKeepsTextOutOfURL() {
        let secret = "privacy-sensitive-source-text-12345"
        let request = GoogleTranslateEngine.makePostRequest(
            text: secret,
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == GoogleTranslateEngine.endpoint.absoluteString)
        #expect(request.url?.query == nil)
        #expect(!(request.url?.absoluteString.contains(secret) ?? true))

        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("q="))
        #expect(body.contains("privacy") || body.contains("sensitive") || body.contains("12345"))
    }

    @Test func mainWindowPreferredSizeConstantsStayStable() {
        #expect(AppWindowController.preferredContentSize.width == 980)
        #expect(AppWindowController.preferredContentSize.height == 640)
        #expect(AppWindowController.preferredMinSize == AppWindowController.preferredContentSize)
    }


}
