import Foundation
import OpenAI

struct OpenAIResponsesStreamError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct OpenAIResponsesStreamAccumulator {
    private(set) var finalText = ""

    mutating func consume(_ event: ResponseStreamEvent) throws -> String? {
        switch event {
        case .outputText(.delta(let delta)):
            finalText += delta.delta
            return finalText
        case .outputText(.done(let done)):
            finalText = done.text
            return finalText
        case .completed(let completed):
            if finalText.isEmpty {
                finalText = Self.text(from: completed.response)
            }
            return finalText.isEmpty ? nil : finalText
        case .failed(let failed), .incomplete(let failed):
            throw OpenAIResponsesStreamError(
                message: failed.response.error?.message ?? "Responses 流式请求未完成"
            )
        case .error(let error):
            throw OpenAIResponsesStreamError(message: error.message)
        default:
            return nil
        }
    }

    private static func text(from response: ResponseObject) -> String {
        if let outputText = response.outputText, !outputText.isEmpty {
            return outputText
        }
        return response.output.flatMap { item -> [String] in
            guard case .outputMessage(let message) = item else { return [] }
            return message.content.compactMap { content in
                guard case .outputTextContent(let text) = content else { return nil }
                return text.text
            }
        }.joined(separator: "\n")
    }
}
