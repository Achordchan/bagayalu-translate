import Foundation

/// L1 内存 + L2 本地持久的两级缓存（PRD §21.1）。
///
/// 读永远只走内存，所以命中时能满足 PRD §51「< 30ms 进入 UI 更新」；
/// 落盘是节流后的后台写，不挡候选展示。
actor InputAssistTranslationCacheStore {
    static let shared = InputAssistTranslationCacheStore()

    private var index: InputAssistCacheIndex
    private let fileURL: URL?
    private var hasLoaded = false
    private var isDirty = false
    private var flushTask: Task<Void, Never>?
    private let flushDelayNanoseconds: UInt64

    init(
        index: InputAssistCacheIndex = InputAssistCacheIndex(),
        fileURL: URL? = InputAssistTranslationCacheStore.defaultFileURL(),
        flushDelayNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.index = index
        self.fileURL = fileURL
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "dazuofanyiguan"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("InputAssistTranslationCache.json", isDirectory: false)
    }

    func value(for key: InputAssistCacheKey) -> String? {
        loadIfNeeded()
        return index.value(for: key.storageKey)
    }

    func store(_ translatedText: String, for key: InputAssistCacheKey) {
        let trimmed = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loadIfNeeded()
        index.insert(translatedText, for: key.storageKey)
        markDirty()
    }

    /// 设置页展示用（PRD §21.3）。
    func usageByteCount() -> Int {
        loadIfNeeded()
        return index.totalByteCount
    }

    func entryCount() -> Int {
        loadIfNeeded()
        return index.count
    }

    /// 清除缓存不得动语言配置、快捷键、Provider 设置和开关（PRD §21.3）——
    /// 所以这里只碰缓存文件本身。
    func clear() {
        index.removeAll()
        hasLoaded = true
        isDirty = false
        flushTask?.cancel()
        flushTask = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        writeToDisk()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([InputAssistCacheEntry].self, from: data) else {
            // 文件损坏时直接当作空缓存重来，不要让它把整个功能拖住。
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        index.load(decoded)
    }

    private func markDirty() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [flushDelayNanoseconds] in
            try? await Task.sleep(nanoseconds: flushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self.performScheduledFlush()
        }
    }

    private func performScheduledFlush() {
        flushTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        guard isDirty, let fileURL else { return }
        isDirty = false
        let entries = index.sortedEntries()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 缓存写不进去不影响功能，下次再试即可，不打扰用户。
            isDirty = true
        }
    }
}
