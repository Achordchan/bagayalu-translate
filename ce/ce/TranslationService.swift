import Foundation
import Combine

struct TranslationResult {
    let text: String
    let detectedLanguage: String?
}

enum TranslationError: Error {
    case invalidResponse
    case networkError(Error)
    case apiError(String)
    case invalidURL
    case missingApiKey(String)
}

extension TranslationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无效的响应，请稍后重试"
        case .networkError(let error):
            return "网络错误：\(error.localizedDescription)"
        case .apiError(let message):
            return "API错误：\(message)"
        case .invalidURL:
            return "无效的服务地址"
        case .missingApiKey(let service):
            return "\(service) API Key 未设置或无效，请在设置中配置正确的 API Key"
        }
    }
}

enum TranslationType: String, CaseIterable {
    case deepL = "DeepL"
    case google = "Google"
    case deepSeek = "DeepSeek AI"
    
    var description: String {
        switch self {
        case .deepL:
            return "DeepL API"
        case .google:
            return "Google 翻译"
        case .deepSeek:
            return "DeepSeek AI"
        }
    }
}

class TranslationService: ObservableObject {
    static let shared = TranslationService()
    private var deeplApiKey: String = ""
    private var deepSeekApiKey: String = ""
    private var deepSeekPrompt: String = "You are a professional translator. Please translate the following text accurately while maintaining its original meaning and style:"
    
    private let queue = DispatchQueue(label: "com.translator.service", qos: .userInitiated)
    
    @Published private(set) var currentType: TranslationType = .google
    @Published private(set) var serviceStatus: [TranslationType: Bool] = [:]
    @Published private(set) var isCheckingService: Set<TranslationType> = []
    
    private let deeplEndpoint = "https://api-free.deepl.com/v2/translate"
    private let fallbackEndpoint = "https://translate.googleapis.com/translate_a/single"
    private let deepSeekEndpoint = "https://api.deepseek.com/v1/chat/completions"
    
    private init() {
        checkAllServices()
    }
    
    func setTranslationType(_ type: TranslationType) {
        DispatchQueue.main.async { [weak self] in
            self?.currentType = type
        }
        checkService(type)
    }
    
    func checkAllServices() {
        TranslationType.allCases.forEach { checkService($0) }
    }
    
    func checkService(_ type: TranslationType) {
        DispatchQueue.main.async { [weak self] in
            self?.isCheckingService.insert(type)
        }
        switch type {
        case .google:
            checkGoogleService()
        case .deepL:
            checkDeepLService()
        case .deepSeek:
            checkDeepSeekService()
        }
    }
    
    private func checkGoogleService() {
        let testText = "test"
        translate(text: testText, sourceLang: "en", targetLang: "zh")
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .finished:
                        self?.serviceStatus[.google] = true
                    case .failure:
                        self?.serviceStatus[.google] = false
                    }
                    self?.isCheckingService.remove(.google)
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
    }
    
    private func checkDeepLService() {
        guard !deeplApiKey.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.serviceStatus[.deepL] = false
                self?.isCheckingService.remove(.deepL)
            }
            return
        }
        
        let testText = "test"
        translateWithDeepL(text: testText, sourceLang: "en", targetLang: "ZH")
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .finished:
                        self?.serviceStatus[.deepL] = true
                    case .failure:
                        self?.serviceStatus[.deepL] = false
                    }
                    self?.isCheckingService.remove(.deepL)
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
    }
    
    private func checkDeepSeekService() {
        guard !deepSeekApiKey.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.serviceStatus[.deepSeek] = false
                self?.isCheckingService.remove(.deepSeek)
            }
            return
        }
        
        let testText = "test"
        translateWithDeepSeek(text: testText, sourceLang: "en", targetLang: "zh")
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    switch completion {
                    case .finished:
                        self?.serviceStatus[.deepSeek] = true
                    case .failure:
                        self?.serviceStatus[.deepSeek] = false
                    }
                    self?.isCheckingService.remove(.deepSeek)
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    func translate(text: String, sourceLang: String = "auto", targetLang: String = "ZH") -> AnyPublisher<TranslationResult, TranslationError> {
        switch currentType {
        case .deepL where !deeplApiKey.isEmpty:
            return translateWithDeepL(text: text, sourceLang: sourceLang, targetLang: targetLang)
        case .deepSeek where !deepSeekApiKey.isEmpty:
            return translateWithDeepSeek(text: text, sourceLang: sourceLang, targetLang: targetLang)
        case .google:
            return fallbackTranslation(text: text, sourceLang: sourceLang, targetLang: targetLang)
        case .deepL:
            return Fail(error: TranslationError.missingApiKey("DeepL")).eraseToAnyPublisher()
        case .deepSeek:
            return Fail(error: TranslationError.missingApiKey("DeepSeek")).eraseToAnyPublisher()
        }
    }
    
    private func fallbackTranslation(text: String, sourceLang: String, targetLang: String) -> AnyPublisher<TranslationResult, TranslationError> {
        let detectedLang = sourceLang == "auto" ? detectLanguage(text) : nil
        let actualSourceLang = detectedLang ?? sourceLang
        
        guard var components = URLComponents(string: fallbackEndpoint) else {
            return Fail(error: TranslationError.invalidURL).eraseToAnyPublisher()
        }
        
        let formattedSourceLang = formatLanguageCode(actualSourceLang, for: .google)
        let formattedTargetLang = formatLanguageCode(targetLang, for: .google)
        
        // 将文本按段落分割，保持更好的上下文
        let paragraphs = text.components(separatedBy: "\n\n")
        let nonEmptyParagraphs = paragraphs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        return Future { promise in
            var translatedParagraphs: [String] = Array(repeating: "", count: nonEmptyParagraphs.count)
            let group = DispatchGroup()
            var error: TranslationError?
            
            let timeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                if error == nil {
                    error = .networkError(NSError(domain: "Translation", code: -1, userInfo: [NSLocalizedDescriptionKey: "翻译超时"]))
                    promise(.failure(error!))
                }
            }
            
            for (index, paragraph) in nonEmptyParagraphs.enumerated() {
                group.enter()
                
                components.queryItems = [
                    URLQueryItem(name: "client", value: "gtx"),
                    URLQueryItem(name: "sl", value: formattedSourceLang),
                    URLQueryItem(name: "tl", value: formattedTargetLang),
                    URLQueryItem(name: "dt", value: "t"),
                    URLQueryItem(name: "dj", value: "1"),
                    URLQueryItem(name: "q", value: paragraph)
                ]
                
                guard let url = components.url else {
                    group.leave()
                    error = .invalidURL
                    continue
                }
                
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                
                let task = URLSession.shared.dataTask(with: request) { data, response, urlError in
                    defer { group.leave() }
                    
                    if let urlError = urlError {
                        error = .networkError(urlError)
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        error = .invalidResponse
                        return
                    }
                    
                    guard let data = data else {
                        error = .invalidResponse
                        return
                    }
                    
                    do {
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let sentences = json["sentences"] as? [[String: Any]] {
                            let translatedText = sentences.compactMap { $0["trans"] as? String }.joined()
                            if !translatedText.isEmpty {
                                translatedParagraphs[index] = translatedText
                            } else {
                                error = .invalidResponse
                            }
                        } else {
                            error = .invalidResponse
                        }
                    } catch let jsonError {
                        error = .networkError(jsonError)
                    }
                }
                
                task.resume()
            }
            
            group.notify(queue: .main) {
                timeoutTimer.invalidate()
                
                if let error = error {
                    promise(.failure(error))
                    return
                }
                
                // 重新组合翻译后的段落，保持原始格式
                let finalText = translatedParagraphs.joined(separator: "\n\n")
                promise(.success(TranslationResult(
                    text: finalText,
                    detectedLanguage: detectedLang ?? actualSourceLang
                )))
            }
        }
        .eraseToAnyPublisher()
    }
    
    private func detectLanguage(_ text: String) -> String? {
        // 移除数字和标点符号，只保留文本内容进行检测
        let cleanText = text.components(separatedBy: .punctuationCharacters).joined()
            .components(separatedBy: .decimalDigits).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanText.isEmpty else { return nil }
        
        let nsText = cleanText as NSString
        
        // 检查每种语言的字符出现频率
        let patterns: [(pattern: String, lang: String)] = [
            ("[\u{0400}-\u{04FF}]", "ru"),           // 俄语
            ("[\u{4E00}-\u{9FFF}]", "zh"),           // 中文
            ("[\u{3040}-\u{309F}\u{30A0}-\u{30FF}]", "ja"),  // 日语
            ("[\u{AC00}-\u{D7AF}]", "ko"),           // 韩语
            ("[a-zA-Z]", "en")                       // 英语
        ]
        
        var maxCount = 0
        var detectedLang: String?
        
        for (pattern, lang) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let count = regex.numberOfMatches(in: cleanText, range: NSRange(location: 0, length: nsText.length))
                if count > maxCount {
                    maxCount = count
                    detectedLang = lang
                }
            }
        }
        
        // 如果检测到的字符数量太少，返回 nil
        if Double(maxCount) / Double(cleanText.count) < 0.1 {
            return nil
        }
        
        return detectedLang
    }
    
    private func translateWithDeepSeek(text: String, sourceLang: String, targetLang: String) -> AnyPublisher<TranslationResult, TranslationError> {
        guard let components = URLComponents(string: deepSeekEndpoint) else {
            return Fail(error: TranslationError.invalidURL).eraseToAnyPublisher()
        }
        
        let sourceLanguage = sourceLang == "auto" ? "auto" : Language.nameForCode(sourceLang)
        let targetLanguage = Language.nameForCode(targetLang)
        
        // 如果是自动检测，先尝试检测语言
        let detectedLang = sourceLang == "auto" ? detectLanguage(text) : nil
        
        // 为文言文翻译定制提示词
        let prompt: String
        if targetLang == "classicalChinese" {
            prompt = """
            你是一位精通中国古代文言文的翻译大师。请将以下文本翻译成优雅的文言文，要求：
            1. 使用典雅的文言文语法和用词
            2. 保持原文的意境和风格
            3. 适当使用典故和成语
            4. 遵循文言文的简洁特点
            
            Source Language: \(detectedLang != nil ? Language.nameForCode(detectedLang!) : sourceLanguage)
            Text: \(text)
            
            Translation:
            """
        } else {
            prompt = """
            \(deepSeekPrompt)
            
            Source Language: \(detectedLang != nil ? Language.nameForCode(detectedLang!) : sourceLanguage)
            Target Language: \(targetLanguage)
            Text: \(text)
            
            Translation:
            """
        }
        
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": targetLang == "classicalChinese" ? 0.7 : 0.3  // 文言文翻译需要更多创造性
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return Fail(error: TranslationError.invalidResponse).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(deepSeekApiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw TranslationError.invalidResponse
                }
                return data
            }
            .tryMap { data -> TranslationResult in
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw TranslationError.invalidResponse
                }
                
                return TranslationResult(
                    text: content.trimmingCharacters(in: .whitespacesAndNewlines),
                    detectedLanguage: detectedLang ?? sourceLang
                )
            }
            .mapError { error -> TranslationError in
                if let error = error as? TranslationError {
                    return error
                }
                return TranslationError.networkError(error)
            }
            .eraseToAnyPublisher()
    }
    
    func setDeepLApiKey(_ key: String) {
        queue.async { [weak self] in
            self?.deeplApiKey = key
            if !key.isEmpty {
                DispatchQueue.main.async {
                    self?.currentType = .deepL
                }
            }
        }
    }
    
    func setDeepSeekApiKey(_ key: String) {
        queue.async { [weak self] in
            self?.deepSeekApiKey = key
            if !key.isEmpty {
                DispatchQueue.main.async {
                    self?.currentType = .deepSeek
                }
            }
        }
    }
    
    func setDeepSeekPrompt(_ prompt: String) {
        queue.async { [weak self] in
            self?.deepSeekPrompt = prompt
        }
    }
    
    private func translateWithDeepL(text: String, sourceLang: String, targetLang: String) -> AnyPublisher<TranslationResult, TranslationError> {
        guard var components = URLComponents(string: deeplEndpoint) else {
            return Fail(error: TranslationError.invalidURL).eraseToAnyPublisher()
        }
        
        let formattedSourceLang = formatLanguageCode(sourceLang, for: .deepL)
        let formattedTargetLang = formatLanguageCode(targetLang, for: .deepL)
        
        var queryItems = [
            URLQueryItem(name: "auth_key", value: deeplApiKey),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "target_lang", value: formattedTargetLang)
        ]
        
        if formattedSourceLang != "auto" {
            queryItems.append(URLQueryItem(name: "source_lang", value: formattedSourceLang))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            return Fail(error: TranslationError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw TranslationError.invalidResponse
                }
                return data
            }
            .decode(type: DeepLResponse.self, decoder: JSONDecoder())
            .tryMap { response -> TranslationResult in
                guard let translation = response.translations.first else {
                    throw TranslationError.invalidResponse
                }
                return TranslationResult(
                    text: translation.text,
                    detectedLanguage: translation.detectedSourceLanguage
                )
            }
            .mapError { error -> TranslationError in
                if let error = error as? TranslationError {
                    return error
                }
                return TranslationError.networkError(error)
            }
            .eraseToAnyPublisher()
    }
    
    private func formatLanguageCode(_ code: String, for service: TranslationType) -> String {
        if code == "auto" { return "auto" }
        
        let baseCode = code.split(separator: "-").first?.description ?? code
        
        switch service {
        case .deepL:
            return baseCode.uppercased()
        case .google:
            switch baseCode.lowercased() {
            case "zh": return "zh-CN"
            case "en": return "en-US"
            case "ja": return "ja-JP"
            case "ko": return "ko-KR"
            default: return baseCode.lowercased()
            }
        case .deepSeek:
            switch baseCode.lowercased() {
            case "zh": return "zh-CN"
            case "en": return "en-US"
            case "ja": return "ja-JP"
            case "ko": return "ko-KR"
            default: return baseCode.lowercased()
            }
        }
    }
    
    func getAISuggestion(prompt: String) -> AnyPublisher<String, TranslationError> {
        guard !deepSeekApiKey.isEmpty else {
            return Fail(error: TranslationError.missingApiKey("DeepSeek")).eraseToAnyPublisher()
        }
        
        guard let components = URLComponents(string: deepSeekEndpoint) else {
            return Fail(error: TranslationError.invalidURL).eraseToAnyPublisher()
        }
        
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.5,
            "max_tokens": 250
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return Fail(error: TranslationError.invalidResponse).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(deepSeekApiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .tryMap { data, response -> Data in
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw TranslationError.invalidResponse
                }
                return data
            }
            .tryMap { data -> String in
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw TranslationError.invalidResponse
                }
                
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .mapError { error -> TranslationError in
                if let error = error as? TranslationError {
                    return error
                }
                return TranslationError.networkError(error)
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Response Models
private struct DeepLResponse: Codable {
    struct Translation: Codable {
        let text: String
        let detectedSourceLanguage: String?
    }
    let translations: [Translation]
} 