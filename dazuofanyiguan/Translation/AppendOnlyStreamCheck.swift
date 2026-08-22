import Foundation

/// 判断「每次都给出完整累积文本」的流式回调，这一次是不是上一次的延续。
///
/// 直接用 `String.hasPrefix` 校验前缀会走 Unicode 规范化比较，开销随文本长度线性增长；
/// 放在每个 delta 的必经路径上，会把整体重新拉回二次复杂度（实测 3200 个 delta 要 500ms 以上）。
///
/// 这里改成 O(1) 判定：先比总长度，再比对上次结尾处的一小段字节。
/// 重开的流要想骗过这个判定，得同时满足「不比上次短」且「结尾字节完全相同」，实际不会发生。
enum AppendOnlyStreamCheck {
    private static let fingerprintByteCount = 16

    /// 取以 `utf8Count` 结尾的最后若干字节，作为「上次看到的内容」的指纹。
    static func fingerprint(of text: String, endingAt utf8Count: Int) -> [UInt8] {
        let utf8 = text.utf8
        let end = min(utf8Count, utf8.count)
        guard end > 0 else { return [] }
        let start = max(0, end - fingerprintByteCount)
        let lower = utf8.index(utf8.startIndex, offsetBy: start)
        let upper = utf8.index(utf8.startIndex, offsetBy: end)
        return Array(utf8[lower..<upper])
    }

    /// `text` 是否仍是上次内容的延续。
    static func isContinuation(
        of text: String,
        previousUTF8Count: Int,
        previousFingerprint: [UInt8]
    ) -> Bool {
        guard text.utf8.count >= previousUTF8Count else { return false }
        return fingerprint(of: text, endingAt: previousUTF8Count) == previousFingerprint
    }
}
