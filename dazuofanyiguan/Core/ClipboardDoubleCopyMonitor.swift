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

    var onDoubleCopy: ((String) -> Void)?

    func start(windowMs: Int, log: LogStore) {
        stop()
        isRunning = true
        runningWindowMs = windowMs
        lastChangeCount = pasteboard.changeCount
        lastChangeDate = nil
        latestString = pasteboard.string(forType: .string)

        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tick(windowMs: windowMs, log: log)
        }
        RunLoop.main.add(timer!, forMode: .common)
        Task { @MainActor in
            log.info("剪贴板监听已启动")
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
        if delta <= Double(windowMs) {
            // 不强制要求两次内容完全一致：只要时间窗口足够短，就认为是“连按两次复制”。
            let text = newString ?? latestString ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { @MainActor in
                    log.warn("检测到双复制，但剪贴板无文本")
                }
                return
            }
            Task { @MainActor in
                log.info("检测到双复制（\(Int(delta))ms）")
            }
            onDoubleCopy?(text)
        }
    }
}
