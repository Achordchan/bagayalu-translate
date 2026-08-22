import Foundation
import OpenAI

struct OpenAIResponsesStreamError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct OpenAIResponsesStreamAccumulator {
    /// 一次文本更新。
    struct Update {
        /// 完整的累积文本。
        let text: String
        /// true 表示这不是在上一次结果后面追加，而是服务端给出的权威全文替换。
        /// 下游的增量状态必须先重置再处理，不能当成追加。
        let replacesPreviousText: Bool
    }

    private(set) var finalText = ""

    mutating func consume(_ event: ResponseStreamEvent) throws -> Update? {
        switch event {
        case .outputText(.delta(let delta)):
            finalText += delta.delta
            return Update(text: finalText, replacesPreviousText: false)
        case .outputText(.done(let done)):
            // 服务端在这里给出权威全文，可能与逐个 delta 拼出来的不完全一致。
            finalText = done.text
            return Update(text: finalText, replacesPreviousText: true)
        case .completed(let completed):
            if finalText.isEmpty {
                finalText = Self.text(from: completed.response)
            }
            return finalText.isEmpty
                ? nil
                : Update(text: finalText, replacesPreviousText: true)
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
