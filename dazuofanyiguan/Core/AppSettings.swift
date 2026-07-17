import Foundation
import SwiftUI

enum AppTextFontSize {
    static let defaultValue: Double = 15
    static let allowedRange: ClosedRange<Double> = 12...24
    static let tickValues: [Double] = [12, 15, 18, 21, 24]

    static func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let clamped = min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
        return clamped.rounded()
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("engineType") var engineTypeRawValue: String = TranslationEngineType.apple.rawValue

    @AppStorage("sourceLanguageCode") var sourceLanguageCode: String = LanguagePreset.auto.code
    @AppStorage("targetLanguageCode") var targetLanguageCode: String = "zh-CN"

    @AppStorage("openAIBaseURL") var openAIBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAIModel") var openAIModel: String = ""
    @AppStorage("openAIEndpointMode") var openAIEndpointModeRawValue: String = OpenAIEndpointMode.chatCompletions.rawValue

    @AppStorage("appearance") var appearanceRawValue: String = AppAppearance.system.rawValue

    @AppStorage("sourceTextFontSize") var sourceTextFontSize: Double = AppTextFontSize.defaultValue
    @AppStorage("translatedTextFontSize") var translatedTextFontSize: Double = AppTextFontSize.defaultValue
    @AppStorage("miniTextFontSize") var miniTextFontSize: Double = AppTextFontSize.defaultValue

    @AppStorage("doubleCopyEnabled") var doubleCopyEnabled: Bool = true
    @AppStorage("doubleCopyWindowMs") var doubleCopyWindowMs: Int = 550

    @AppStorage("globalHotkeyEnabled") var globalHotkeyEnabled: Bool = false
    @AppStorage("neverRecommendGlobalHotkey") var neverRecommendGlobalHotkey: Bool = false
    @AppStorage("globalHotkeyRecommendationAfter") var globalHotkeyRecommendationAfter: Double = 0
    @AppStorage("miniModeEnabled") var miniModeEnabled: Bool = false

    @AppStorage("screenshotHotkeyEnabled") var screenshotHotkeyEnabled: Bool = true

    @AppStorage("screenshotHotkeyKeyCode") var screenshotHotkeyKeyCode: Int = 7

    @AppStorage("screenshotFreezeBackgroundEnabled") var screenshotFreezeBackgroundEnabled: Bool = true

    init() {
        sourceTextFontSize = AppTextFontSize.sanitized(sourceTextFontSize)
        translatedTextFontSize = AppTextFontSize.sanitized(translatedTextFontSize)
        miniTextFontSize = AppTextFontSize.sanitized(miniTextFontSize)

        let modelMigrationKey = "didMigrateOpenAIModelDefaultV1"
        if !UserDefaults.standard.bool(forKey: modelMigrationKey) {
            if openAIBaseURL == "https://api.openai.com/v1", openAIModel == "gpt-4o-mini" {
                openAIModel = ""
            }
            UserDefaults.standard.set(true, forKey: modelMigrationKey)
        }

        let engineMigrationKey = "didMigrateAppleTranslationDefaultV2"
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: engineMigrationKey) {
            let storedEngine = defaults.string(forKey: "engineType")
            if storedEngine == nil || storedEngine == TranslationEngineType.google.rawValue {
                engineTypeRawValue = TranslationEngineType.apple.rawValue
                defaults.set(TranslationEngineType.apple.rawValue, forKey: "engineType")
            }
            defaults.set(true, forKey: engineMigrationKey)
        }
    }

    var engineType: TranslationEngineType {
        get { TranslationEngineType(rawValue: engineTypeRawValue) ?? .apple }
        set { engineTypeRawValue = newValue.rawValue }
    }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: appearanceRawValue) ?? .system }
        set { appearanceRawValue = newValue.rawValue }
    }

    var openAIEndpointMode: OpenAIEndpointMode {
        get { OpenAIEndpointMode(rawValue: openAIEndpointModeRawValue) ?? .chatCompletions }
        set { openAIEndpointModeRawValue = newValue.rawValue }
    }

    @discardableResult
    func preferGlobalHotkeyWhenAvailable(
        isAccessibilityTrusted: Bool,
        permissionWasMissing: Bool
    ) -> Bool {
        let migrationKey = "didPreferGlobalHotkeyWhenAvailableV2"
        let defaults = UserDefaults.standard
        guard ShortcutPermissionPolicy.shouldPreferGlobalHotkey(
            isAccessibilityTrusted: isAccessibilityTrusted,
            permissionWasMissing: permissionWasMissing,
            isTextShortcutEnabled: globalHotkeyEnabled || doubleCopyEnabled,
            hasAppliedPreferredDefault: defaults.bool(forKey: migrationKey)
        ) else {
            return false
        }

        globalHotkeyEnabled = true
        doubleCopyEnabled = false
        defaults.set(true, forKey: migrationKey)
        return true
    }

    func shouldRecommendGlobalHotkey(
        isAccessibilityTrusted: Bool,
        globalMonitorFailed: Bool,
        now: Date = Date()
    ) -> Bool {
        ShortcutRecommendationPolicy.shouldRecommendGlobalHotkey(
            isAccessibilityTrusted: isAccessibilityTrusted,
            isTextShortcutEnabled: globalHotkeyEnabled || doubleCopyEnabled,
            isClipboardModeSelected: doubleCopyEnabled && !globalHotkeyEnabled,
            globalMonitorFailed: globalMonitorFailed,
            isNeverReminderEnabled: neverRecommendGlobalHotkey,
            reminderAvailableAt: Date(timeIntervalSince1970: globalHotkeyRecommendationAfter),
            now: now
        )
    }

    func snoozeGlobalHotkeyRecommendation(now: Date = Date()) {
        globalHotkeyRecommendationAfter = now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970
    }
}

enum ShortcutPermissionPolicy {
    static func shouldPreferGlobalHotkey(
        isAccessibilityTrusted: Bool,
        permissionWasMissing: Bool,
        isTextShortcutEnabled: Bool,
        hasAppliedPreferredDefault: Bool
    ) -> Bool {
        isAccessibilityTrusted
            && isTextShortcutEnabled
            && (permissionWasMissing || !hasAppliedPreferredDefault)
    }
}

enum ShortcutRecommendationPolicy {
    static func shouldRecommendGlobalHotkey(
        isAccessibilityTrusted: Bool,
        isTextShortcutEnabled: Bool,
        isClipboardModeSelected: Bool,
        globalMonitorFailed: Bool,
        isNeverReminderEnabled: Bool,
        reminderAvailableAt: Date,
        now: Date
    ) -> Bool {
        isAccessibilityTrusted
            && isTextShortcutEnabled
            && (isClipboardModeSelected || globalMonitorFailed)
            && !isNeverReminderEnabled
            && now >= reminderAvailableAt
    }
}

enum OpenAIEndpointMode: String, CaseIterable, Identifiable {
    case chatCompletions
    case responses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatCompletions: return "Chat Completions"
        case .responses: return "Responses"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
