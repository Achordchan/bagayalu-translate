import Foundation

enum TranslationEngineType: String, CaseIterable, Identifiable {
    case google
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google 翻译"
        case .openAICompatible: return "OpenAI 通用接口"
        }
    }
}
