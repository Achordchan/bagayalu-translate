import Foundation

/// 双复制触发规则的纯逻辑，便于单测与监控实现复用。
enum ClipboardDoubleCopyPolicy {
    /// 判断两次剪贴板文本是否构成“同内容双复制”。
    static func isMatchingDoubleCopy(
        previous: String?,
        current: String?,
        intervalMs: Double,
        windowMs: Int
    ) -> Bool {
        guard intervalMs <= Double(windowMs) else { return false }

        let prev = previous?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let curr = current?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !curr.isEmpty else { return false }
        return prev == curr
    }

    /// 是否应抑制重复触发（窗口期内同一文本已触发过）。
    static func shouldSuppressDuplicateEmission(
        lastEmittedText: String?,
        lastEmittedDate: Date?,
        currentText: String,
        now: Date,
        windowMs: Int
    ) -> Bool {
        guard let lastEmittedText,
              let lastEmittedDate,
              lastEmittedText == currentText else {
            return false
        }
        return now.timeIntervalSince(lastEmittedDate) * 1000 <= Double(windowMs)
    }
}
