import Foundation

/// 截图翻译按段翻译的调度：在线引擎分批、分不回原段数时逐段重来、失败怎么处理。
/// 不碰界面和具体引擎，翻译调用从外部传进来，方便单测。
///
/// 失败分两类：
/// - 整体性的（断网、超时、被取消、鉴权失败、限流、服务端出错）：后面的段再试也一样，立刻停下。
/// - 和语言有关的（Apple 不支持这个语言对、语言包没装上、服务端拒绝这门语言）：
///   只影响用这个源语言的段。记下这门语言，同语言的其他段不再尝试（免得同一个缺失的语言包
///   一段一段反复弹下载框），换别的语言的段照常翻。自动检测（`auto`）的段不这样熔断：
///   每一段实际是什么语言可能都不一样。
///
/// 没翻成的段一律保留原文。
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
    }

    /// 在线引擎合批请求；Apple 本地翻译逐段翻。
    let batchesRequests: Bool
    let translate: (_ text: String, _ sourceLanguageCode: String) async -> Result<String, Error>

    /// `shouldContinue` 返回 false 时（选区已经换了）立即放弃，返回 nil。
    /// `onProgress` 在每段 / 每批翻完后带上目前为止的结果调用。
    func run(
        _ jobs: [Job],
        shouldContinue: () -> Bool,
        onProgress: ([UUID: String]) -> Void
    ) async -> Outcome? {
        var outcome = Outcome()
        var failedSources: Set<String> = []

        func translateOne(_ job: Job) async {
            if failedSources.contains(job.sourceLanguageCode) {
                outcome.translations[job.id] = job.text
                return
            }
            switch await translate(job.text, job.sourceLanguageCode) {
            case .success(let text):
                outcome.translations[job.id] = text
                outcome.succeeded += 1
            case .failure(let error):
                outcome.translations[job.id] = job.text
                outcome.failures.append(error)
                if Self.isRequestWide(error) {
                    outcome.stoppedEarly = true
                } else if job.sourceLanguageCode != LanguagePreset.auto.code {
                    failedSources.insert(job.sourceLanguageCode)
                }
            }
        }

        let groups = batchesRequests ? Self.batches(jobs) : jobs.map { [$0] }
        for group in groups {
            guard shouldContinue() else { return nil }
            if outcome.stoppedEarly {
                for job in group { outcome.translations[job.id] = job.text }
                continue
            }

            var handled = false
            if group.count > 1, !failedSources.contains(group[0].sourceLanguageCode) {
                // 一批里的段用换行分隔，走现有的换行标记机制；分不回原来的段数就逐段重来。
                let result = await translate(group.map(\.text).joined(separator: "\n"), group[0].sourceLanguageCode)
                guard shouldContinue() else { return nil }
                switch result {
                case .success(let text):
                    let parts = text.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if parts.count == group.count {
                        for (job, part) in zip(group, parts) {
                            outcome.translations[job.id] = part
                        }
                        outcome.succeeded += group.count
                        handled = true
                    }
                case .failure(let error):
                    // 整体性失败不用再逐段试一遍。
                    if Self.isRequestWide(error) {
                        outcome.failures.append(error)
                        outcome.stoppedEarly = true
                        for job in group { outcome.translations[job.id] = job.text }
                        handled = true
                    }
                }
            }
            if !handled {
                for job in group {
                    guard shouldContinue() else { return nil }
                    if outcome.stoppedEarly {
                        outcome.translations[job.id] = job.text
                    } else {
                        await translateOne(job)
                    }
                }
            }
            guard shouldContinue() else { return nil }
            onProgress(outcome.translations)
        }
        return outcome
    }

    /// 相邻、同源语言的段合成一批；每批最多 14 段、约 2200 字，沿用原先 OpenAI 分块的上限：
    /// 一次太长容易超限或不稳定。
    nonisolated static func batches(_ jobs: [Job]) -> [[Job]] {
        let maxJobsPerBatch = 14
        let maxCharactersPerBatch = 2200

        var batches: [[Job]] = []
        var current: [Job] = []
        var characters = 0
        for job in jobs {
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

    /// 后面的段再试也一样会失败的错误。
    nonisolated static func isRequestWide(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError {
            return true
        }
        if error is OpenAICompatibleEngine.RateLimitError {
            return true
        }
        if case .badStatus(let code, _)? = error as? HTTPClient.HTTPError {
            return code == 401 || code == 403 || code == 429 || code >= 500
        }
        return (error as NSError).domain == NSURLErrorDomain
    }
}
