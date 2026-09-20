import Foundation

enum TranslationEngineType: String, CaseIterable, Identifiable {
    case apple
    case google
    case microsoft
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple 本地翻译"
        case .google: return "Google 翻译"
        case .microsoft: return "微软翻译"
        case .openAICompatible: return "OpenAI 通用接口"
        }
    }

    var systemImageName: String {
        switch self {
        case .apple: return "apple.logo"
        case .google: return "g.circle.fill"
        case .microsoft: return "m.circle.fill"
        case .openAICompatible: return "sparkles"
        }
    }
}
