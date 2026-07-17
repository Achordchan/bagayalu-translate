import AppKit
import Foundation

final class ClipboardDoubleCopyMonitor: ObservableObject {
    private var timer: Timer?

    private(set) var isRunning: Bool = false
    private(set) var runningWindowMs: Int = 0

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastChangeDate: Date?
    private var latestString: String?
    private var lastEmittedText: String?
    private var lastEmittedDate: Date?

    var onDoubleCopy: ((String) -> Void)?

    func start(windowMs: Int, log: LogStore) {
        stop()
        isRunning = true
        runningWindowMs = windowMs
        lastChangeCount = pasteboard.changeCount
        lastChangeDate = nil
        latestString = pasteboard.string(forType: .string)
        lastEmittedText = nil
        lastEmittedDate = nil

        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tick(windowMs: windowMs, log: log)
        }
        RunLoop.main.add(timer!, forMode: .common)
        Task { @MainActor in
            log.info("剪贴板监听已启动（需两次相同文本）")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        runningWindowMs = 0
    }

    private func tick(windowMs: Int, log: LogStore) {
        let change = pasteboard.changeCount
        if change == lastChangeCount { return }

        lastChangeCount = change
        let now = Date()
        let newString = pasteboard.string(forType: .string)

        defer {
            latestString = newString
            lastChangeDate = now
        }

        guard let lastChangeDate else { return }
        let delta = now.timeIntervalSince(lastChangeDate) * 1000
        let previous = latestString
        let currentRaw = newString
        let current = currentRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard ClipboardDoubleCopyPolicy.isMatchingDoubleCopy(
            previous: previous,
            current: currentRaw,
            intervalMs: delta,
            windowMs: windowMs
        ) else {
            if delta <= Double(windowMs) {
                if current.isEmpty {
                    Task { @MainActor in
                        log.warn("检测到快速剪贴板变化，但无文本")
                    }
                } else {
                    Task { @MainActor in
                        log.info("剪贴板快速变化但内容不一致，已忽略")
                    }
                }
            }
            return
        }

        if ClipboardDoubleCopyPolicy.shouldSuppressDuplicateEmission(
            lastEmittedText: lastEmittedText,
            lastEmittedDate: lastEmittedDate,
            currentText: current,
            now: now,
            windowMs: windowMs
        ) {
            return
        }

        lastEmittedText = current
        lastEmittedDate = now
        Task { @MainActor in
            log.info("检测到双复制（\(Int(delta))ms，内容一致）")
        }
        onDoubleCopy?(current)
    }
}
