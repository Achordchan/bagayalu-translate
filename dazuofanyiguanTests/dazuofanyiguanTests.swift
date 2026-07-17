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

}
