import Foundation
import OpenAI

final class OpenAISDKResponseCapture: OpenAIMiddleware, @unchecked Sendable {
    struct Snapshot {
        let statusCode: Int?
        let body: String
        let responseShape: String
        let isResponsesRequest: Bool
    }

    private let lock = NSLock()
    private var statusCode: Int?
    private var body = ""
    private var responseShape = ""
    private var isResponsesRequest = false

    func reset() {
        lock.lock()
        statusCode = nil
        body = ""
        responseShape = ""
        isResponsesRequest = false
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let value = Snapshot(
            statusCode: statusCode,
            body: body,
            responseShape: responseShape,
            isResponsesRequest: isResponsesRequest
        )
        lock.unlock()
        return value
    }

    func intercept(
        response: URLResponse?,
        request: URLRequest,
        data: Data?
    ) -> (response: URLResponse?, data: Data?) {
        lock.lock()
        statusCode = (response as? HTTPURLResponse)?.statusCode
        body = data.map(HTTPClient.sanitizedErrorBody(from:)) ?? ""
        responseShape = OpenAIResponsesResponseNormalizer.shapeDescription(from: data)
        isResponsesRequest = request.url?.path.hasSuffix("/responses") == true
        lock.unlock()
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        guard let statusCode, (200...299).contains(statusCode) else {
            return (response, data)
        }
        return (response, OpenAIResponsesResponseNormalizer.normalize(data, for: request))
    }
}

struct OpenAIResponsesDecodingError: LocalizedError {
    let decodingMessage: String
    let responseShape: String

    var errorDescription: String? {
        "Responses 返回成功，但格式与标准协议不兼容（\(decodingMessage)）。\(responseShape)"
    }
}

struct OpenAISDKTransport {
    private let client: OpenAI
    private let responseCapture: OpenAISDKResponseCapture

    init(baseURL: URL, apiKey: String, session: URLSession) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else {
            throw OpenAICompatibleEngine.EngineError.invalidBaseURL()
        }

        let defaultPort = scheme.lowercased() == "http" ? 80 : 443
        let capture = OpenAISDKResponseCapture()
        let configuration = OpenAI.Configuration(
            token: apiKey,
            host: host,
            port: components.port ?? defaultPort,
            scheme: scheme,
            basePath: components.path,
            timeoutInterval: 60,
            parsingOptions: .relaxed
        )
        self.client = OpenAI(
            configuration: configuration,
            session: session,
            middlewares: [capture]
        )
        self.responseCapture = capture
    }

    func chatContent(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double?
    ) async throws -> String {
        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent(systemPrompt))),
                .user(.init(content: .string(userPrompt)))
            ],
            model: model,
            temperature: temperature
        )
        let result: ChatResult = try await perform {
            try await client.chats(query: query)
        }
        return result.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func responsesContent(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double?,
        useMinimalPayload: Bool
    ) async throws -> String {
        let input: CreateModelResponseQuery.Input
        let instructions: String?
        if useMinimalPayload {
            input = .textInput("\(systemPrompt)\n\n\(userPrompt)")
            instructions = nil
        } else {
            input = .textInput(userPrompt)
            instructions = systemPrompt
        }

        let query = CreateModelResponseQuery(
            input: input,
            model: model,
            instructions: instructions,
            temperature: useMinimalPayload ? nil : temperature
        )
        let result: ResponseObject = try await perform {
            try await client.responses.createResponse(query: query)
        }
        if let outputText = result.outputText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !outputText.isEmpty {
            return outputText
        }

        let outputTexts = result.output.flatMap { item -> [String] in
            guard case .outputMessage(let message) = item else { return [] }
            return message.content.compactMap { content in
                guard case .outputTextContent(let textContent) = content else { return nil }
                let text = textContent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        return outputTexts.joined(separator: "\n")
    }

    func responsesContentStreaming(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double?,
        useMinimalPayload: Bool,
        onPartialText: @escaping @MainActor (_ text: String, _ replacesPreviousText: Bool) -> Void
    ) async throws -> String {
        let input: CreateModelResponseQuery.Input
        let instructions: String?
        if useMinimalPayload {
            input = .textInput("\(systemPrompt)\n\n\(userPrompt)")
            instructions = nil
        } else {
            input = .textInput(userPrompt)
            instructions = systemPrompt
        }

        let query = CreateModelResponseQuery(
            input: input,
            model: model,
            instructions: instructions,
            stream: true,
            temperature: useMinimalPayload ? nil : temperature
        )
        let stream: AsyncThrowingStream<ResponseStreamEvent, Error> =
            client.responses.createResponseStreaming(query: query)
        var accumulator = OpenAIResponsesStreamAccumulator()
        // 这是一条全新的流，第一次回调必须让下游重置增量状态：
        // 同一个回调会被兼容性回退和原文回显重试复用。
        var isFirstUpdate = true
        for try await event in stream {
            try Task.checkCancellation()
            if let update = try accumulator.consume(event) {
                await onPartialText(
                    update.text,
                    update.replacesPreviousText || isFirstUpdate
                )
                isFirstUpdate = false
            }
        }
        return accumulator.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func perform<Result: Sendable>(
        operation: () async throws -> Result
    ) async throws -> Result {
        responseCapture.reset()
        do {
            let result = try await operation()
            let snapshot = responseCapture.snapshot()
            if let statusCode = snapshot.statusCode, !(200...299).contains(statusCode) {
                throw HTTPClient.HTTPError.badStatus(code: statusCode, body: snapshot.body)
            }
            return result
        } catch {
            let snapshot = responseCapture.snapshot()
            if let statusCode = snapshot.statusCode, !(200...299).contains(statusCode) {
                throw HTTPClient.HTTPError.badStatus(code: statusCode, body: snapshot.body)
            }
            if snapshot.isResponsesRequest,
               snapshot.statusCode.map({ (200...299).contains($0) }) == true,
               error is DecodingError {
                throw OpenAIResponsesDecodingError(
                    decodingMessage: String(describing: error),
                    responseShape: snapshot.responseShape
                )
            }
            throw error
        }
    }
}
