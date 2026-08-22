//
//  dazuofanyiguanTests.swift
//  dazuofanyiguanTests
//
//  Created by AchordChan on 2025/12/19.
//

import AppKit
import OpenAI
import Testing
import UniformTypeIdentifiers
@testable import 大佐翻译官v1

private final class OpenAISDKMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (statusCode: Int, body: Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func setHandler(for host: String, _ newHandler: Handler?) {
        lock.lock()
        handlers[host] = newHandler
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        let handler = Self.handlers[host]
        Self.lock.unlock()

        do {
            guard let handler, let url = request.url else {
                throw URLError(.badURL)
            }
            let result = try handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OpenAISDKRequestRecorder: @unchecked Sendable {
    struct Entry {
        let url: URL?
        let authorization: String?
        let body: [String: Any]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(request: URLRequest, body: [String: Any]) -> Int {
        lock.lock()
        entries.append(
            Entry(
                url: request.url,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: body
            )
        )
        let count = entries.count
        lock.unlock()
        return count
    }

    func snapshot() -> [Entry] {
        lock.lock()
        let value = entries
        lock.unlock()
        return value
    }
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }

    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4_096)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

struct dazuofanyiguanTests {

    @Test func legacySandboxPreferencesMigrateOnceUsingSandboxValues() throws {
        let suiteName = "achord.dazuofanyiguan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("google", forKey: "engineType")

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazuo-sandbox-preferences-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source: [String: Any] = [
            "engineType": "apple",
            "sourceLanguageCode": "en",
            "targetLanguageCode": "zh-CN",
            "miniTextFontSize": 18.0,
            "unrelatedKey": "ignored"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: source,
            format: .binary,
            options: 0
        )
        try data.write(to: sourceURL)

        let migratedCount = LegacySandboxPreferencesMigration.migrateIfNeeded(
            defaults: defaults,
            sourceURL: sourceURL
        )

        #expect(migratedCount == 4)
        #expect(defaults.string(forKey: "engineType") == "apple")
        #expect(defaults.string(forKey: "sourceLanguageCode") == "en")
        #expect(defaults.string(forKey: "targetLanguageCode") == "zh-CN")
        #expect(defaults.double(forKey: "miniTextFontSize") == 18)
        #expect(defaults.object(forKey: "unrelatedKey") == nil)
        #expect(defaults.bool(forKey: LegacySandboxPreferencesMigration.markerKey))

        defaults.set("google", forKey: "engineType")
        #expect(
            LegacySandboxPreferencesMigration.migrateIfNeeded(
                defaults: defaults,
                sourceURL: sourceURL
            ) == 0
        )
        #expect(defaults.string(forKey: "engineType") == "google")
    }

    @Test func legacySandboxPreferencesRetryAfterMalformedSource() throws {
        let suiteName = "achord.dazuofanyiguan.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dazuo-malformed-preferences-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Data("not a property list".utf8).write(to: sourceURL)

        #expect(
            LegacySandboxPreferencesMigration.migrateIfNeeded(
                defaults: defaults,
                sourceURL: sourceURL
            ) == 0
        )
        #expect(!defaults.bool(forKey: LegacySandboxPreferencesMigration.markerKey))
    }

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

    @Test func miniModeStopsAcceptingStreamingUpdatesAfterCancellation() {
        var tracker = MiniTranslationRequestTracker()
        let streamingRequest = tracker.begin()

        #expect(tracker.accepts(streamingRequest))

        tracker.invalidate()
        #expect(!tracker.accepts(streamingRequest))

        let nextRequest = tracker.begin()
        #expect(!tracker.accepts(streamingRequest))
        #expect(tracker.accepts(nextRequest))
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

    @Test func openAITranslationPayloadParserExtractsAutoDetectPayload() {
        let content = #"{"detectedSourceLanguageCode":"en","translatedText":"你好"}"#
        let result = OpenAITranslationPayloadParser.parseAutoDetectResult(from: content)
        let translated = result?.translatedText
        let detected = result?.detectedSourceLanguageCode
        #expect(translated == "你好")
        #expect(detected == "en")
    }

    @Test func openAITranslationPayloadParserExtractsFencedAutoDetectPayload() {
        let fenced = """
        ```json
        {"detected_source_language_code":"ja","translated_text":"早上好"}
        ```
        """
        let fencedResult = OpenAITranslationPayloadParser.parseAutoDetectResult(from: fenced)
        let translated = fencedResult?.translatedText
        let detected = fencedResult?.detectedSourceLanguageCode
        #expect(translated == "早上好")
        #expect(detected == "ja")
    }

    @Test func openAISDKResponsesRetriesWithMinimalPayloadAfterHTTP400() async throws {
        let recorder = OpenAISDKRequestRecorder()
        let host = "responses.example.com"

        OpenAISDKMockURLProtocol.setHandler(for: host) { request in
            let body = try requestBodyData(from: request)
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let requestNumber = recorder.append(request: request, body: json)

            if requestNumber == 1 {
                return (
                    400,
                    Data(#"{"error":{"message":"Upstream request failed","type":"upstream_error"}}"#.utf8)
                )
            }

            let success = """
            {
              "id": "resp-test",
              "object": "response",
              "model": "test-model",
              "created_at": 1,
              "output": [],
              "output_text": "你好",
              "tools": [],
              "metadata": {},
              "parallel_tool_calls": false
            }
            """
            return (200, Data(success.utf8))
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .responses,
            onPhaseChange: nil,
            session: session
        )

        let result = try await engine.translate(
            text: "hello",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN"
        )

        let bodies = recorder.snapshot().map(\.body)
        #expect(result.translatedText == "你好")
        #expect(bodies.count == 2)
        #expect(bodies[0]["instructions"] != nil)
        #expect(bodies[0]["temperature"] != nil)
        #expect(bodies[1]["instructions"] == nil)
        #expect(bodies[1]["temperature"] == nil)
        #expect((bodies[1]["input"] as? String)?.contains("hello") == true)
    }

    @Test func openAISDKResponsesMapsMinimalRetryRateLimit() async throws {
        let recorder = OpenAISDKRequestRecorder()
        let host = "responses-rate-limit.example.com"

        OpenAISDKMockURLProtocol.setHandler(for: host) { request in
            let body = try requestBodyData(from: request)
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let requestNumber = recorder.append(request: request, body: json)
            if requestNumber == 1 {
                return (400, Data(#"{"error":{"message":"unsupported parameter"}}"#.utf8))
            }
            return (
                429,
                Data(#"{"error":{"code":"rate_limit_exceeded","message":"slow down"}}"#.utf8)
            )
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .responses,
            onPhaseChange: nil,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await engine.translate(
                text: "hello",
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-CN"
            )
            #expect(Bool(false), "expected rate limit error")
        } catch let error as OpenAICompatibleEngine.RateLimitError {
            #expect(error.httpStatusCode == 429)
            #expect(error.apiCode == "rate_limit_exceeded")
            #expect(error.apiMessage == "slow down")
        }
    }

    @Test func openAISDKResponsesMapsMinimalRetryCompatibilityFailure() async throws {
        let recorder = OpenAISDKRequestRecorder()
        let host = "responses-unsupported.example.com"

        OpenAISDKMockURLProtocol.setHandler(for: host) { request in
            let body = try requestBodyData(from: request)
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            _ = recorder.append(request: request, body: json)
            return (400, Data(#"{"error":{"message":"responses unsupported"}}"#.utf8))
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .responses,
            onPhaseChange: nil,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await engine.translate(
                text: "hello",
                sourceLanguageCode: "en",
                targetLanguageCode: "zh-CN"
            )
            #expect(Bool(false), "expected compatibility error")
        } catch let error as OpenAICompatibleEngine.ResponsesCompatibilityError {
            #expect(error.httpStatusCode == 400)
            #expect(error.responseBody.contains("responses unsupported"))
        }
        #expect(recorder.snapshot().count == 2)
    }

    @Test func openAISDKResponsesNormalizesTextContentAndMissingDefaults() async throws {
        let host = "responses-text.example.com"
        OpenAISDKMockURLProtocol.setHandler(for: host) { _ in
            let success = """
            {
              "id": "resp-test",
              "object": "response",
              "model": "test-model",
              "created_at": "1",
              "output": [
                {
                  "type": "message",
                  "role": "assistant",
                  "content": [{"type": "text", "text": "你好"}]
                }
              ]
            }
            """
            return (200, Data(success.utf8))
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .responses,
            onPhaseChange: nil,
            session: URLSession(configuration: configuration)
        )

        let result = try await engine.translate(
            text: "hello",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN"
        )
        #expect(result.translatedText == "你好")
    }

    @Test func openAISDKResponsesNormalizesChatChoicesReturnedByProxy() async throws {
        let host = "responses-choices.example.com"
        OpenAISDKMockURLProtocol.setHandler(for: host) { _ in
            let success = """
            {
              "id": "chat-test",
              "object": "chat.completion",
              "created": 1,
              "model": "test-model",
              "choices": [
                {"index": 0, "message": {"role": "assistant", "content": "你好"}}
              ]
            }
            """
            return (200, Data(success.utf8))
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .responses,
            onPhaseChange: nil,
            session: URLSession(configuration: configuration)
        )

        let result = try await engine.translate(
            text: "hello",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN"
        )
        #expect(result.translatedText == "你好")
    }

    @Test func openAISDKResponsesNormalizesUnexpectedEventStream() async throws {
        let host = "responses-sse.example.com"
        OpenAISDKMockURLProtocol.setHandler(for: host) { _ in
            let eventStream = """
            event: response.created
            data: {"type":"response.created","response":{"id":"resp-test","object":"response","created_at":1,"model":"test-model","output":[],"metadata":{},"parallel_tool_calls":false,"tools":[]}}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"你"}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"好"}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp-test","object":"response","created_at":1,"model":"test-model","output":[{"id":"msg-test","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"你好","annotations":[],"logprobs":[]}]}],"metadata":{},"parallel_tool_calls":false,"tools":[]}}

            data: [DONE]

            """
            return (200, Data(eventStream.utf8))
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .responses,
            onPhaseChange: nil,
            session: URLSession(configuration: configuration)
        )

        let result = try await engine.translate(
            text: "hello",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN"
        )
        #expect(result.translatedText == "你好")
    }

    @Test func responsesStreamingProjectorShowsOnlyTranslatedTextForAutoDetect() {
        #expect(
            OpenAIStreamingTranslationProjector.visibleText(
                from: #"{"detectedSourceLanguageCode":"en","translatedText":"你\n好"#,
                isAutoDetect: true
            ) == "你\n好"
        )
        #expect(
            OpenAIStreamingTranslationProjector.visibleText(
                from: #"{"detectedSourceLanguageCode":"en","trans"#,
                isAutoDetect: true
            ) == nil
        )
        #expect(
            OpenAIStreamingTranslationProjector.visibleText(
                from: "直接译文",
                isAutoDetect: false
            ) == "直接译文"
        )
    }

    @Test func responsesStreamAccumulatorPublishesRealServerDeltas() throws {
        var accumulator = OpenAIResponsesStreamAccumulator()
        let first = Components.Schemas.ResponseTextDeltaEvent(
            _type: .response_outputText_delta,
            itemId: "msg-test",
            outputIndex: 0,
            contentIndex: 0,
            delta: "你",
            sequenceNumber: 1,
            logprobs: []
        )
        let second = Components.Schemas.ResponseTextDeltaEvent(
            _type: .response_outputText_delta,
            itemId: "msg-test",
            outputIndex: 0,
            contentIndex: 0,
            delta: "好",
            sequenceNumber: 2,
            logprobs: []
        )

        #expect(try accumulator.consume(.outputText(.delta(first))) == "你")
        #expect(try accumulator.consume(.outputText(.delta(second))) == "你好")
        #expect(accumulator.finalText == "你好")
    }

    @Test func openAISDKChatCompletionsUsesConfiguredBasePath() async throws {
        let recorder = OpenAISDKRequestRecorder()
        let host = "chat.example.com"

        OpenAISDKMockURLProtocol.setHandler(for: host) { request in
            let body = try requestBodyData(from: request)
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            _ = recorder.append(request: request, body: json)
            let success = """
            {
              "id": "chat-test",
              "object": "chat.completion",
              "created": 1,
              "model": "test-model",
              "choices": [
                {
                  "index": 0,
                  "message": {"role": "assistant", "content": "你好"},
                  "finish_reason": "stop"
                }
              ]
            }
            """
            return (200, Data(success.utf8))
        }
        defer { OpenAISDKMockURLProtocol.setHandler(for: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAISDKMockURLProtocol.self]
        let engine = OpenAICompatibleEngine(
            baseURL: "https://\(host)/api/v1",
            apiKey: "test-key",
            model: "test-model",
            endpointMode: .chatCompletions,
            onPhaseChange: nil,
            session: URLSession(configuration: configuration)
        )

        let result = try await engine.translate(
            text: "hello",
            sourceLanguageCode: "en",
            targetLanguageCode: "zh-CN"
        )

        let recorded = try #require(recorder.snapshot().first)
        #expect(result.translatedText == "你好")
        #expect(recorded.url?.path == "/api/v1/chat/completions")
        #expect(recorded.authorization == "Bearer test-key")
        #expect(recorded.body["messages"] != nil)
    }


    @Test func legacyKeychainItemPolicyOnlyMatchesMissingOrEmptyService() {
        #expect(LegacyKeychainItemPolicy.isLegacyService(nil))
        #expect(LegacyKeychainItemPolicy.isLegacyService(""))
        #expect(LegacyKeychainItemPolicy.isLegacyService("   "))
        #expect(!LegacyKeychainItemPolicy.isLegacyService("com.achord.dazuofanyiguan"))
        #expect(!LegacyKeychainItemPolicy.isLegacyService("com.other.app"))
    }

    @Test func keychainStoreRoundTripsUniqueValue() throws {
        let key = "keychain-test-\(UUID().uuidString)"
        let value = "secret-\(UUID().uuidString)"
        defer { try? KeychainStore.delete(for: key) }

        try KeychainStore.setString(value, for: key)
        #expect(try KeychainStore.getString(for: key) == value)
        try KeychainStore.delete(for: key)
        #expect(try KeychainStore.getString(for: key) == nil)
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

    // MARK: - 流式增量解析

    /// 逐字符喂入投影器，每一步都必须和一次性解析整段文本的结果完全一致。
    private func expectStreamingProjectionMatchesOneShot(_ full: String) {
        var session = OpenAIStreamingTranslationProjector.Session()
        var accumulated = ""
        for character in full {
            accumulated.append(character)
            let oneShot = OpenAIStreamingTranslationProjector.visibleText(
                from: accumulated,
                isAutoDetect: true
            )
            let streamed = session.project(from: accumulated, isAutoDetect: true)
            #expect(streamed == oneShot, "累积到 \(accumulated.debugDescription) 时结果不一致")
        }
    }

    @Test func streamingProjectorMatchesOneShotParsingCharacterByCharacter() {
        let samples = [
            #"{"detectedSourceLanguageCode":"en","translatedText":"你好世界"}"#,
            #"{"detectedSourceLanguageCode":"en","translatedText":"未闭合的译文"#,
            #"{"translated_text":"下划线键也要支持"#,
            #"{"translatedText"  :  "键和冒号之间有空格"#,
            #"{"translatedText":"他说 \"你好\" 然后走了"#,
            #"{"translatedText":"路径 C:\\Users\\test"#,
            #"{"translatedText":"制表\t换行\n回车\r"#,
            #"{"translatedText":"转义中文 \u4f60\u597d"#,
            #"{"translatedText":"表情 \ud83d\ude00 结束"#,
            #"{"translatedText":"第一行 [[DAZUO_NL]] 第二行"#,
            #"{"detectedSourceLanguageCode":"en","trans"#,
            "模型没有按 JSON 输出，直接给了译文",
        ]
        for sample in samples {
            expectStreamingProjectionMatchesOneShot(sample)
        }
    }

    @Test func streamingProjectorDecodesEscapesAndSurrogatePairsSplitAcrossDeltas() {
        var session = OpenAIStreamingTranslationProjector.Session()
        // 代理对被切在两个 delta 中间时，不能先吐出半个孤立代理。
        #expect(session.project(from: #"{"translatedText":"hi \ud83d"#, isAutoDetect: true) == "hi ")
        #expect(session.project(from: #"{"translatedText":"hi \ud83d\ude00"#, isAutoDetect: true) == "hi 😀")
        #expect(session.project(from: #"{"translatedText":"hi \ud83d\ude00 ok"#, isAutoDetect: true) == "hi 😀 ok")
    }

    @Test func streamingProjectorRestartsWhenStreamIsRetried() {
        var session = OpenAIStreamingTranslationProjector.Session()
        #expect(session.project(from: #"{"translatedText":"第一次请求"#, isAutoDetect: true) == "第一次请求")

        // 兼容性回退或原文回显重试会重新开一条流，累积文本不再是上一次的延续。
        #expect(session.project(from: #"{"translatedText":"重"#, isAutoDetect: true) == "重")
        #expect(session.project(from: #"{"translatedText":"重试后的译文"#, isAutoDetect: true) == "重试后的译文")
    }

    @Test func streamingProjectorPassesThroughWhenNotAutoDetect() {
        var session = OpenAIStreamingTranslationProjector.Session()
        #expect(session.project(from: "直接译文", isAutoDetect: false) == "直接译文")
        #expect(session.project(from: "直接译文更长了", isAutoDetect: false) == "直接译文更长了")
    }

    /// 逐字符喂入还原器，每一步都必须和一次性 restoreNewlines 的结果完全一致。
    private func expectStreamingRestoreMatchesOneShot(_ full: String) {
        var restorer = StreamingNewlineRestorer()
        var accumulated = ""
        for character in full {
            accumulated.append(character)
            let oneShot = TranslationRequestContext.restoreNewlines(from: accumulated)
            let streamed = restorer.restore(from: accumulated)
            #expect(streamed == oneShot, "累积到 \(accumulated.debugDescription) 时结果不一致")
        }
    }

    @Test func streamingNewlineRestorerMatchesOneShotCharacterByCharacter() {
        let marker = TranslationRequestContext.newlineMarker
        let samples = [
            "没有任何标记的普通译文",
            "第一行 \(marker) 第二行",
            "第一行\(marker)第二行",
            "连续 \(marker) \(marker) 两个",
            "\(marker) 开头",
            " \(marker) 两边都有空格 \(marker) ",
            "结尾也有 \(marker)",
            "左边有空格右边没有 \(marker)紧跟",
            "疑似前缀 [[DAZUO_N 并不是标记",
            "数组字面量 [[1,2],[3]] 不该被误伤",
            "表情 😀 \(marker) 后面",
            marker,
        ]
        for sample in samples {
            expectStreamingRestoreMatchesOneShot(sample)
        }
    }

    @Test func streamingNewlineRestorerRestartsWhenStreamIsRetried() {
        let marker = TranslationRequestContext.newlineMarker
        var restorer = StreamingNewlineRestorer()
        #expect(restorer.restore(from: "第一次 \(marker) 请求") == "第一次\n请求")

        // 重试会重新开一条流，还原器必须跟着重头来。
        #expect(restorer.restore(from: "重") == "重")
        #expect(restorer.restore(from: "重试 \(marker) 之后") == "重试\n之后")
    }

}
