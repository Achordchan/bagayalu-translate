import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("engineType") var engineTypeRawValue: String = TranslationEngineType.google.rawValue

    @AppStorage("sourceLanguageCode") var sourceLanguageCode: String = LanguagePreset.auto.code
    @AppStorage("targetLanguageCode") var targetLanguageCode: String = "zh-CN"

    @AppStorage("openAIBaseURL") var openAIBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAIModel") var openAIModel: String = ""
    @AppStorage("openAIEndpointMode") var openAIEndpointModeRawValue: String = OpenAIEndpointMode.chatCompletions.rawValue

    @AppStorage("appearance") var appearanceRawValue: String = AppAppearance.system.rawValue

    @AppStorage("doubleCopyEnabled") var doubleCopyEnabled: Bool = true
    @AppStorage("doubleCopyWindowMs") var doubleCopyWindowMs: Int = 550

    @AppStorage("globalHotkeyEnabled") var globalHotkeyEnabled: Bool = false

    @AppStorage("screenshotHotkeyEnabled") var screenshotHotkeyEnabled: Bool = true

    @AppStorage("screenshotHotkeyKeyCode") var screenshotHotkeyKeyCode: Int = 7

    @AppStorage("screenshotFreezeBackgroundEnabled") var screenshotFreezeBackgroundEnabled: Bool = true

    init() {
        let key = "didMigrateOpenAIModelDefaultV1"
        if !UserDefaults.standard.bool(forKey: key) {
            if openAIBaseURL == "https://api.openai.com/v1", openAIModel == "gpt-4o-mini" {
                openAIModel = ""
            }
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    var engineType: TranslationEngineType {
        get { TranslationEngineType(rawValue: engineTypeRawValue) ?? .google }
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
