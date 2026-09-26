import Foundation
import NaturalLanguage
import OpenAI

/// 截图翻译按段翻译的调度：在线引擎分批、分不回原段数时逐段重来、太长的段拆开翻、失败怎么处理。
/// 不碰界面和具体引擎，翻译调用从外部传进来，方便单测。
///
/// 失败分三类：
/// - 整体性的（断网、超时、被取消、鉴权失败、限流、服务端出错）：后面的段再试也一样，立刻停下。
/// - 语言组合本身用不了（Apple 报告不支持这个语言对）：同语言的其他段不再尝试，换别的语言的段照常翻。
///   自动检测（`auto`）的段不这样熔断：每一段实际是什么语言可能都不一样。
/// - 其余都只算这一次请求的问题（空响应、个别请求被拒）：这一段保留原文，其他段照常翻。
///
/// 没翻成的段一律保留原文。
///
/// 一段超过单次请求的上限（`maxCharactersPerRequest`）就按句子拆成几块分别翻，译完拼回原来的段；
/// 有一块没翻成，整段保留原文，免得半段原文半段译文。
///
/// 第一遍译完，`followUpSource` 说还要补翻的（目标是中文、译文里还留着另一种字形的字），按第一遍的译文再翻一次；
/// 补翻失败就保留第一遍的译文，不重复计入成功段数，但记进 `Outcome.unconverted`，提示用户。
@MainActor
struct ScreenshotBlockTranslator {
    struct Job {
        let id: UUID
        let text: String
        let sourceLanguageCode: String
    }

    struct Outcome {
        /// 所有段的最终文字：翻好的是译文，没翻成的是原文。
        var translations: [UUID: String] = [:]
        var succeeded = 0
        var failures: [Error] = []
        /// 因为整体性失败提前停下了。
        var stoppedEarly = false
        /// 第一遍翻好了、补翻（简繁转换）没成功的段数；这些段保留第一遍的译文。
        var unconverted = 0

        /// 没翻完整时给用户的提示；都翻好了返回 nil。`targetName` 是目标语言的名字。
        func incompleteWarning(jobCount: Int, targetName: String) -> String? {
            let untranslated = jobCount - succeeded
            let reason = failures.first.map { "（\($0.localizedDescription)）" } ?? ""
            switch (untranslated > 0, unconverted > 0) {
            case (true, true):
                return "有 \(untranslated) 段没翻译成功，已保留原文；另有 \(unconverted) 段没转换成\(targetName)\(reason)"
            case (true, false):
                return "有 \(untranslated) 段没翻译成功，已保留原文\(reason)"
            case (false, true):
                return "有 \(unconverted) 段没转换成\(targetName)，已保留未转换的译文\(reason)"
            case (false, false):
                return nil
            }
        }
    }

    /// 单次请求最多多少字：合批不超过它，单独一段超过它就拆开。取 2200，是原先 OpenAI 分块的大小，
    /// 也在 Google（8000）、微软（30000）的单次上限以内——请求里的换行标记会让实际长度再多一点。
    nonisolated static let defaultMaxCharactersPerRequest = 2200

    /// 在线引擎合批请求；Apple 本地翻译逐段翻。
    let batchesRequests: Bool
    let translate: (_ text: String, _ sourceLanguageCode: String) async -> Result<String, Error>
    /// 第一遍的译文还要不要按另一种源语言补翻一次；nil 表示不用。
    var followUpSource: (_ translation: String) -> String? = { _ in nil }
    var maxCharactersPerRequest = Self.defaultMaxCharactersPerRequest

    /// `shouldContinue` 返回 false 时（选区已经换了）立即放弃，返回 nil。
    /// `onProgress` 在每段 / 每批翻完后带上目前为止的结果调用（只含已经有结果的段）。
    func run(
        _ jobs: [Job],
        shouldContinue: () -> Bool,
        onProgress: ([UUID: String]) -> Void
    ) async -> Outcome? {
        // 以下都按「块」记：没拆的段就是一块、沿用段的 id。
        let pieces = jobs.map { Self.split($0, maxCharacters: maxCharactersPerRequest) }
        var translations: [UUID: String] = [:]
        var translatedIDs: Set<UUID> = []
        var convertedIDs: Set<UUID> = []
        var failures: [Error] = []
        var stoppedEarly = false
        var failedSources: Set<String> = []

        /// 拼回按段的结果：所有块都有了结果才算这一段有结果；有一块没翻成，整段保留原文。
        func assembled() -> [UUID: String] {
            var result: [UUID: String] = [:]
            for (job, chunks) in zip(jobs, pieces) {
                let parts = chunks.compactMap { translatedIDs.contains($0.id) ? translations[$0.id] : nil }
                if parts.count == chunks.count {
                    result[job.id] = parts.dropFirst().reduce(parts[0]) { OCRParagraphGrouper.joinLines($0, $1) }
                } else if chunks.allSatisfy({ translations[$0.id] != nil }) {
                    result[job.id] = job.text
                }
            }
            return result
        }

        // 补翻（`isFollowUp`）失败时不覆盖第一遍的译文。
        func translateOne(_ job: Job, isFollowUp: Bool) async {
            if failedSources.contains(job.sourceLanguageCode) {
                if !isFollowUp { translations[job.id] = job.text }
                return
            }
            switch await translate(job.text, job.sourceLanguageCode) {
            case .success(let text):
                translations[job.id] = text
                if isFollowUp {
                    convertedIDs.insert(job.id)
                } else {
                    translatedIDs.insert(job.id)
                }
            case .failure(let error):
                if !isFollowUp { translations[job.id] = job.text }
                failures.append(error)
                if Self.isRequestWide(error) {
                    stoppedEarly = true
                } else if Self.isLanguagePairUnavailable(error),
                          job.sourceLanguageCode != LanguagePreset.auto.code {
                    failedSources.insert(job.sourceLanguageCode)
                }
            }
        }

        /// 翻一轮；选区换了返回 false。
        func translateAll(_ jobs: [Job], isFollowUp: Bool) async -> Bool {
            let groups = batchesRequests
                ? Self.batches(jobs, maxCharacters: maxCharactersPerRequest)
                : jobs.map { [$0] }
            for group in groups {
                guard shouldContinue() else { return false }
                if stoppedEarly {
                    if !isFollowUp {
                        for job in group { translations[job.id] = job.text }
                    }
                    continue
                }

                var handled = false
                if group.count > 1, !failedSources.contains(group[0].sourceLanguageCode) {
                    // 一批里的块用换行分隔，走现有的换行标记机制；分不回原来的块数就逐块重来。
                    let result = await translate(group.map(\.text).joined(separator: "\n"), group[0].sourceLanguageCode)
                    guard shouldContinue() else { return false }
                    switch result {
                    case .success(let text):
                        let parts = text.components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if parts.count == group.count {
                            for (job, part) in zip(group, parts) {
                                translations[job.id] = part
                            }
                            if isFollowUp {
                                convertedIDs.formUnion(group.map(\.id))
                            } else {
                                translatedIDs.formUnion(group.map(\.id))
                            }
                            handled = true
                        }
                    case .failure(let error):
                        // 整体性失败不用再逐块试一遍。
                        if Self.isRequestWide(error) {
                            failures.append(error)
                            stoppedEarly = true
                            if !isFollowUp {
                                for job in group { translations[job.id] = job.text }
                            }
                            handled = true
                        }
                    }
                }
                if !handled {
                    for job in group {
                        guard shouldContinue() else { return false }
                        if stoppedEarly {
                            if !isFollowUp { translations[job.id] = job.text }
                        } else {
                            await translateOne(job, isFollowUp: isFollowUp)
                        }
                    }
                }
                guard shouldContinue() else { return false }
                onProgress(assembled())
            }
            return true
        }

        guard await translateAll(pieces.flatMap { $0 }, isFollowUp: false) else { return nil }

        let followUps = pieces.flatMap { $0 }.compactMap { chunk -> Job? in
            guard translatedIDs.contains(chunk.id),
                  let translation = translations[chunk.id],
                  let source = followUpSource(translation),
                  source != chunk.sourceLanguageCode else { return nil }
            return Job(id: chunk.id, text: translation, sourceLanguageCode: source)
        }
        if !followUps.isEmpty, !stoppedEarly {
            guard await translateAll(followUps, isFollowUp: true) else { return nil }
        }

        let followUpIDs = Set(followUps.map(\.id))
        let fullyTranslated = pieces.filter { $0.allSatisfy { translatedIDs.contains($0.id) } }
        var outcome = Outcome()
        outcome.translations = assembled()
        outcome.succeeded = fullyTranslated.count
        outcome.failures = failures
        outcome.stoppedEarly = stoppedEarly
        outcome.unconverted = fullyTranslated.filter { chunks in
            chunks.contains { followUpIDs.contains($0.id) && !convertedIDs.contains($0.id) }
        }.count
        return outcome
    }

    /// 超过上限的段按句子拆成几块，一句本身太长再按空白、最后按字数硬拆。没超的原样返回（沿用原来的 id）。
    nonisolated static func split(_ job: Job, maxCharacters: Int) -> [Job] {
        guard job.text.count > maxCharacters, maxCharacters > 0 else { return [job] }
        let text = job.text
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { text[$0] }
        if sentences.isEmpty { sentences = [text[...]] }
        // 分句器不管句子之间的空白，补回去，拼起来和原文一模一样。
        var pieces: [Substring] = []
        var cursor = text.startIndex
        for sentence in sentences {
            if cursor < sentence.startIndex { pieces.append(text[cursor..<sentence.startIndex]) }
            pieces.append(sentence)
            cursor = sentence.endIndex
        }
        if cursor < text.endIndex { pieces.append(text[cursor...]) }

        var chunks: [String] = []
        var current = ""
        for piece in pieces.flatMap({ hardSplit($0, maxCharacters: maxCharacters) }) {
            if current.count + piece.count > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Job(id: UUID(), text: $0, sourceLanguageCode: job.sourceLanguageCode) }
    }

    /// 比上限还长的一句：在上限以内最后一个空白处断开，没有空白（中日文）就按字数断。
    nonisolated private static func hardSplit(_ text: Substring, maxCharacters: Int) -> [Substring] {
        var result: [Substring] = []
        var rest = text
        while rest.count > maxCharacters {
            let limit = rest.index(rest.startIndex, offsetBy: maxCharacters)
            var end = limit
            if let space = rest[..<limit].lastIndex(where: \.isWhitespace), space > rest.startIndex {
                end = rest.index(after: space)
            }
            result.append(rest[..<end])
            rest = rest[end...]
        }
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// 相邻、同源语言的段合成一批；每批最多 14 段、`maxCharacters` 字，沿用原先 OpenAI 分块的上限：
    /// 一次太长容易超限或不稳定。
    /// 源语言没定下来（`auto`）的段各自单独一批：它们不一定是同一种语言，合成一段请求时
    /// 引擎只会整体认一次语言，分回原段数也查不出译错。
    nonisolated static func batches(_ jobs: [Job], maxCharacters: Int = defaultMaxCharactersPerRequest) -> [[Job]] {
        let maxJobsPerBatch = 14
        let maxCharactersPerBatch = maxCharacters

        var batches: [[Job]] = []
        var current: [Job] = []
        var characters = 0
        for job in jobs {
            if job.sourceLanguageCode == LanguagePreset.auto.code {
                if !current.isEmpty {
                    batches.append(current)
                    current = []
                    characters = 0
                }
                batches.append([job])
                continue
            }
            let length = job.text.count + 1
            if let first = current.first,
               first.sourceLanguageCode != job.sourceLanguageCode
                || current.count >= maxJobsPerBatch
                || characters + length > maxCharactersPerBatch {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(job)
            characters += length
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    /// 这个语言组合本身用不了。
    nonisolated static func isLanguagePairUnavailable(_ error: Error) -> Bool {
        (error as? AppleTranslationError)?.isLanguagePairUnavailable ?? false
    }

    /// 后面的段再试也一样会失败的错误。
    nonisolated static func isRequestWide(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError {
            return true
        }
        if error is OpenAICompatibleEngine.RateLimitError || error is OpenAICompatibleEngine.ResponsesCompatibilityError {
            return true
        }
        // 各引擎自己包装过的：Google 的 405/501（这个接口用不了）、微软的限流、OpenAI 的配置错误。
        if case .methodNotAllowed? = error as? GoogleTranslateEngine.EngineError {
            return true
        }
        if case .rateLimited? = error as? MicrosoftTranslateEngine.EngineError {
            return true
        }
        if let engineError = error as? OpenAICompatibleEngine.EngineError {
            switch engineError {
            case .missingAPIKey, .missingModel, .invalidBaseURL:
                return true
            case .emptyResponse:
                return false
            }
        }
        if case .badStatus(let code, _)? = error as? HTTPClient.HTTPError {
            return isRequestWideStatus(code)
        }
        // OpenAI SDK 的三种失败形态：流式请求带状态码；普通请求能解码出错误体时只有 type / code；
        // Gemini 格式的错误体里 code 就是状态码。
        if case .statusError(_, let code)? = error as? OpenAIError {
            return isRequestWideStatus(code)
        }
        if let response = error as? APIErrorResponse {
            let fields = [response.error.type, response.error.code ?? ""].map { $0.lowercased() }
            let markers = ["auth", "permission", "invalid_api_key", "quota", "billing", "rate_limit",
                           "server_error", "overloaded", "model_not_found"]
            return fields.contains { field in markers.contains { field.contains($0) } }
        }
        if let response = error as? GeminiAPIErrorResponse {
            return isRequestWideStatus(response.error.code)
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// 鉴权失败、没权限、限流、服务端出错：换一段文字也一样。
    nonisolated private static func isRequestWideStatus(_ code: Int) -> Bool {
        code == 401 || code == 403 || code == 429 || code >= 500
    }
}
