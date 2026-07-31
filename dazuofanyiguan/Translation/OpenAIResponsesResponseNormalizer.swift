import Foundation

enum OpenAIResponsesResponseNormalizer {
    static func normalize(_ data: Data?, for request: URLRequest) -> Data? {
        guard request.url?.path.hasSuffix("/responses") == true,
              let data,
              var root = responseObject(from: data),
              root["error"] == nil else {
            return data
        }

        root["id"] = root["id"] as? String ?? "resp-compatible"
        root["object"] = "response"
        root["created_at"] = numericValue(root["created_at"]) ?? 0
        root["model"] = root["model"] as? String ?? "unknown"
        root["metadata"] = stringDictionary(root["metadata"]) ?? [:]
        root["parallel_tool_calls"] = root["parallel_tool_calls"] as? Bool ?? false
        root["tools"] = root["tools"] as? [Any] ?? []

        var outputText = root["output_text"] as? String
        var normalizedOutput: [[String: Any]] = []

        if let output = root["output"] as? [Any] {
            for (index, rawItem) in output.enumerated() {
                guard var item = rawItem as? [String: Any] else { continue }
                let type = item["type"] as? String

                if type == "message" || item["role"] as? String == "assistant" {
                    item["id"] = item["id"] as? String ?? "msg-compatible-\(index)"
                    item["type"] = "message"
                    item["role"] = "assistant"
                    item["status"] = item["status"] as? String ?? "completed"

                    let result = normalizeMessageContent(item["content"])
                    item["content"] = result.content
                    if outputText == nil, !result.text.isEmpty {
                        outputText = result.text
                    }
                }

                normalizedOutput.append(item)
            }
        } else if let text = root["output"] as? String {
            outputText = outputText ?? text
        }

        if normalizedOutput.isEmpty,
           let choicesText = textFromChatChoices(root["choices"]) {
            outputText = outputText ?? choicesText
        }

        if normalizedOutput.isEmpty,
           let outputText,
           !outputText.isEmpty {
            normalizedOutput = [messageItem(text: outputText, index: 0)]
        }

        root["output"] = normalizedOutput
        if let outputText {
            root["output_text"] = outputText
        }

        return try? JSONSerialization.data(withJSONObject: root)
    }

    static func shapeDescription(from data: Data?) -> String {
        guard let data else { return "响应体为空" }
        if isEventStream(data) {
            let types = eventPayloads(from: data)
                .compactMap { $0["type"] as? String }
                .uniqued()
                .prefix(8)
                .joined(separator: ",")
            return "响应格式=SSE，事件类型=[\(types)]"
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "响应不是 JSON 对象"
        }

        let rootKeys = root.keys.sorted().joined(separator: ",")
        let outputTypes = (root["output"] as? [[String: Any]])?
            .compactMap { $0["type"] as? String }
            .joined(separator: ",") ?? ""
        let contentTypes = (root["output"] as? [[String: Any]])?
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["type"] as? String }
            .joined(separator: ",") ?? ""
        return "根字段=[\(rootKeys)]，output.type=[\(outputTypes)]，content.type=[\(contentTypes)]"
    }

    private static func responseObject(from data: Data) -> [String: Any]? {
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return root
        }

        let payloads = eventPayloads(from: data)
        guard !payloads.isEmpty else { return nil }

        let finalResponse = payloads.reversed().compactMap {
            $0["response"] as? [String: Any]
        }.first
        let doneText = payloads.reversed().first {
            $0["type"] as? String == "response.output_text.done"
        }?["text"] as? String
        let responseText = finalResponse.flatMap(textFromResponseObject)
        let deltaText = payloads.compactMap { payload -> String? in
            guard payload["type"] as? String == "response.output_text.delta" else { return nil }
            return payload["delta"] as? String
        }.joined()

        if let text = [doneText, responseText, deltaText]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) {
            return canonicalResponse(text: text, source: finalResponse)
        }

        return finalResponse
    }

    private static func textFromResponseObject(_ response: [String: Any]) -> String? {
        if let text = response["output_text"] as? String, !text.isEmpty { return text }
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        let texts = output.compactMap { item -> String? in
            let result = normalizeMessageContent(item["content"])
            return result.text.isEmpty ? nil : result.text
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func canonicalResponse(text: String, source: [String: Any]?) -> [String: Any] {
        [
            "id": source?["id"] as? String ?? "resp-compatible",
            "object": "response",
            "created_at": numericValue(source?["created_at"]) ?? 0,
            "model": source?["model"] as? String ?? "unknown",
            "metadata": [:],
            "parallel_tool_calls": false,
            "tools": [],
            "output_text": text,
            "output": [messageItem(text: text, index: 0)]
        ]
    }

    private static func isEventStream(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(64), encoding: .utf8) else { return false }
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.hasPrefix("event:") || prefix.hasPrefix("data:")
    }

    private static func eventPayloads(from data: Data) -> [[String: Any]] {
        guard isEventStream(data), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return nil }
            let json = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard json != "[DONE]", let payloadData = json.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        }
    }

    private static func normalizeMessageContent(_ rawContent: Any?) -> (content: [[String: Any]], text: String) {
        if let text = rawContent as? String {
            return ([outputTextContent(text)], text)
        }

        guard let values = rawContent as? [Any] else { return ([], "") }
        var content: [[String: Any]] = []
        var texts: [String] = []
        for value in values {
            if let text = value as? String {
                content.append(outputTextContent(text))
                texts.append(text)
                continue
            }
            guard var item = value as? [String: Any] else { continue }
            let type = item["type"] as? String
            if type == "text" || type == "output_text" || (type == nil && item["text"] is String) {
                let text = item["text"] as? String ?? ""
                item["type"] = "output_text"
                item["annotations"] = item["annotations"] as? [Any] ?? []
                item["logprobs"] = item["logprobs"] as? [Any] ?? []
                content.append(item)
                if !text.isEmpty { texts.append(text) }
            } else {
                content.append(item)
            }
        }
        return (content, texts.joined(separator: "\n"))
    }

    private static func textFromChatChoices(_ rawChoices: Any?) -> String? {
        guard let choices = rawChoices as? [[String: Any]] else { return nil }
        let texts = choices.compactMap { choice -> String? in
            guard let message = choice["message"] as? [String: Any] else { return nil }
            if let content = message["content"] as? String { return content }
            let parts = message["content"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func messageItem(text: String, index: Int) -> [String: Any] {
        [
            "id": "msg-compatible-\(index)",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [outputTextContent(text)]
        ]
    }

    private static func outputTextContent(_ text: String) -> [String: Any] {
        ["type": "output_text", "text": text, "annotations": [], "logprobs": []]
    }

    private static func numericValue(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let text = value as? String, let number = Double(text) { return NSNumber(value: number) }
        return nil
    }

    private static func stringDictionary(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if let text = value as? String { result[key] = text }
        }
        return result
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
