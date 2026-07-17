import Foundation

enum LegacySandboxPreferencesMigration {
    static let markerKey = "didMigrateFromSandboxPreferencesV1"

    private static let preferenceKeys = [
        "engineType",
        "sourceLanguageCode",
        "targetLanguageCode",
        "openAIBaseURL",
        "openAIModel",
        "openAIEndpointMode",
        "appearance",
        "sourceTextFontSize",
        "translatedTextFontSize",
        "miniTextFontSize",
        "doubleCopyEnabled",
        "doubleCopyWindowMs",
        "globalHotkeyEnabled",
        "neverRecommendGlobalHotkey",
        "globalHotkeyRecommendationAfter",
        "miniModeEnabled",
        "screenshotHotkeyEnabled",
        "screenshotHotkeyKeyCode",
        "screenshotFreezeBackgroundEnabled",
        "didMigrateOpenAIModelDefaultV1",
        "didMigrateAppleTranslationDefaultV3",
        "didPreferGlobalHotkeyWhenAvailableV2",
        "didAutoEnableScreenshotHotkeyV2"
    ]

    @discardableResult
    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        sourceURL: URL = defaultSourceURL
    ) -> Int {
        guard !defaults.bool(forKey: markerKey) else { return 0 }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            defaults.set(true, forKey: markerKey)
            return 0
        }

        guard
            let data = try? Data(contentsOf: sourceURL),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let source = propertyList as? [String: Any]
        else {
            return 0
        }

        var migratedCount = 0
        for key in preferenceKeys {
            guard let value = source[key] else { continue }
            defaults.set(value, forKey: key)
            migratedCount += 1
        }
        defaults.set(true, forKey: markerKey)
        return migratedCount
    }

    private static var defaultSourceURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/achord.dazuofanyiguan")
            .appendingPathComponent("Data/Library/Preferences/achord.dazuofanyiguan.plist")
    }
}
