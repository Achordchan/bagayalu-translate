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

    @Test func miniBubbleStaysInsideVisibleScreenFrame() {
        let visibleFrame = CGRect(x: 100, y: 100, width: 1_000, height: 700)
        let contentSize = NSSize(width: 420, height: 220)

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

    @Test func miniResultBubbleKeepsReadableContentHeight() {
        let shortResultSize = MiniTranslationLayout.contentSize(for: .result("WebSockets"))
        let multilineResultSize = MiniTranslationLayout.contentSize(
            for: .result("第一行\n第二行\n第三行\n第四行")
        )

        #expect(shortResultSize.height >= 160)
        #expect(multilineResultSize.height >= shortResultSize.height)
        #expect(multilineResultSize.height <= 340)
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
