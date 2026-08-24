import Foundation

/// 缓存键（PRD §21.2）。
///
/// 引擎指纹里必须带上所有会改变译文的参数。OpenAI 之后如果引入
/// prompt / style / temperature，**一定要一起加进 `engineFingerprint`**，
/// 否则换了 prompt 还会命中旧译文。
struct InputAssistCacheKey: Hashable {
    let sourceText: String
    let sourceLanguageCode: String
    let targetLanguageCode: String
    let engineFingerprint: String

    var storageKey: String {
        [engineFingerprint, sourceLanguageCode, targetLanguageCode, sourceText]
            .joined(separator: "\u{1F}")
    }

    static func engineFingerprint(
        engineType: TranslationEngineType,
        openAIBaseURL: String,
        openAIModel: String,
        openAIEndpointMode: OpenAIEndpointMode
    ) -> String {
        switch engineType {
        case .apple, .google:
            return engineType.rawValue
        case .openAICompatible:
            return [
                engineType.rawValue,
                openAIBaseURL,
                openAIModel,
                openAIEndpointMode.rawValue
            ].joined(separator: "\u{1E}")
        }
    }
}

struct InputAssistCacheEntry: Codable, Equatable {
    let key: String
    let translatedText: String
    let createdAt: Date
    var lastUsedSequence: UInt64

    /// 粗略的字节占用：用于 LRU 容量控制和设置页的「已占用 xx MB」。
    var estimatedByteCount: Int {
        key.utf8.count + translatedText.utf8.count + 32
    }
}

/// 两级缓存的内存索引（PRD §21.1 L1）。
///
/// 用「单调递增序号」记录访问顺序，而不是维护一个数组：
/// 数组版本每次命中都要 `firstIndex(of:)` 线性扫一遍，条目一多就是热路径上的
/// 二次复杂度——本仓库在流式译文那条路上已经栽过一次（见开发日志 2026-08-23）。
/// 这里查询和写入都是 O(1)，只有超出容量时才排序淘汰，摊还成本可以忽略。
struct InputAssistCacheIndex: Equatable {
    private(set) var entries: [String: InputAssistCacheEntry] = [:]
    private(set) var totalByteCount: Int = 0
    private var sequence: UInt64 = 0

    let maximumByteCount: Int
    let maximumEntryCount: Int

    init(maximumByteCount: Int = 8 * 1024 * 1024, maximumEntryCount: Int = 5_000) {
        self.maximumByteCount = max(1, maximumByteCount)
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    var count: Int { entries.count }

    mutating func value(for key: String) -> String? {
        guard var entry = entries[key] else { return nil }
        sequence &+= 1
        entry.lastUsedSequence = sequence
        entries[key] = entry
        return entry.translatedText
    }

    mutating func insert(_ translatedText: String, for key: String, createdAt: Date = Date()) {
        sequence &+= 1
        let entry = InputAssistCacheEntry(
            key: key,
            translatedText: translatedText,
            createdAt: createdAt,
            lastUsedSequence: sequence
        )
        if let previous = entries.updateValue(entry, forKey: key) {
            totalByteCount -= previous.estimatedByteCount
        }
        totalByteCount += entry.estimatedByteCount
        evictIfNeeded()
    }

    mutating func removeAll() {
        entries.removeAll()
        totalByteCount = 0
        sequence = 0
    }

    mutating func load(_ loaded: [InputAssistCacheEntry]) {
        entries = Dictionary(loaded.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        totalByteCount = entries.values.reduce(0) { $0 + $1.estimatedByteCount }
        sequence = entries.values.map(\.lastUsedSequence).max() ?? 0
        evictIfNeeded()
    }

    /// 落盘用：按访问顺序从旧到新，下次加载后仍然保有 LRU 次序。
    func sortedEntries() -> [InputAssistCacheEntry] {
        entries.values.sorted { $0.lastUsedSequence < $1.lastUsedSequence }
    }

    private mutating func evictIfNeeded() {
        guard entries.count > maximumEntryCount || totalByteCount > maximumByteCount else {
            return
        }
        // 只有真正超限时才排序，正常写入路径上不会走到这里。
        for entry in sortedEntries() {
            guard entries.count > maximumEntryCount || totalByteCount > maximumByteCount else {
                return
            }
            entries[entry.key] = nil
            totalByteCount -= entry.estimatedByteCount
        }
    }
}
