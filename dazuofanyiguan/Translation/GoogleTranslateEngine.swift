import Foundation

struct GoogleTranslateEngine: TranslationEngine {
    let title: String = "Google 翻译"

    private let http = HTTPClient()

    func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async throws -> TranslationResult {
        guard var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            throw URLError(.badURL)
        }

        components.queryItems = [
            .init(name: "client", value: "gtx"),
            .init(name: "sl", value: sourceLanguageCode),
            .init(name: "tl", value: targetLanguageCode),
            .init(name: "dt", value: "t"),
            .init(name: "q", value: text)
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await http.data(for: request)

        // Google 的这个返回不是标准 JSON schema，这里用 JSONSerialization 以更“宽松”的方式解析。
        let obj = try JSONSerialization.jsonObject(with: data)

        // 典型结构：
        // [
        //   [ ["translated","original",null,null], ... ],
        //   null,
        //   "detectedSourceLang",
        //   ...
        // ]
        guard let root = obj as? [Any] else {
            return .init(translatedText: String(data: data, encoding: .utf8) ?? "", detectedSourceLanguageCode: nil)
        }

        var translated = ""
        if let sentences = root.first as? [Any] {
            for item in sentences {
                if let seg = item as? [Any], let part = seg.first as? String {
                    translated += part
                }
            }
        }

        let detected = root.count > 2 ? root[2] as? String : nil
        return .init(translatedText: translated, detectedSourceLanguageCode: detected)
    }
}
