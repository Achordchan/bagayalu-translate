import Foundation

/// 承载流式还原器状态的盒子。流式回调是 @MainActor 串行执行的，无需额外同步。
@MainActor
final class StreamingNewlineRestorerBox {
    var restorer = StreamingNewlineRestorer()

    init() {}
}

/// 流式换行标记还原器。
///
/// 流式回调每次都会带来「完整的可见译文」。若每次都对全文跑
/// `TranslationRequestContext.restoreNewlines`（两次 replacingOccurrences），
/// 主线程开销会随译文长度呈二次增长。
///
/// 这里只处理相对上一次新增的字符：能确定不会再参与匹配的部分直接定稿，
/// 末尾那一小段可能还是标记前半截的字符留在待定区，每次重新渲染。
/// 待定区长度不会超过一个标记，因此摊还后每个 delta 只付出 O(新增长度) 的代价。
/// 逐字符喂入的结果与一次性调用 `restoreNewlines` 完全一致。
struct StreamingNewlineRestorer {
    /// 带空格的标记优先匹配，与 `restoreNewlines` 先替换 " 标记 " 的顺序一致。
    private static let spacedMarker = Array(" \(TranslationRequestContext.newlineMarker) ")
    private static let bareMarker = Array(TranslationRequestContext.newlineMarker)

    /// 已还原的完整文本，末尾 `renderedPendingCount` 个字符来自待定区。
    private var display = ""
    private var renderedPendingCount = 0
    /// 待定区的原始字符：仍有可能成为某个标记的一部分，还不能定稿。
    private var pendingSource: [Character] = []
    /// 已经消费到的输入位置。用 UTF-8 偏移记录，String.Index 不能跨 String 实例复用。
    private var consumedUTF8Offset = 0
    /// 上一次收到的可见文本长度与结尾指纹，用来确认这次确实是它的延续。
    private var seenUTF8Count = 0
    private var seenFingerprint: [UInt8] = []

    init() {}

    mutating func restore(from visibleText: String) -> String {
        // 可见文本正常只会追加。一旦不是上次内容的延续，说明上游重新发起了一次流式请求，
        // 需要重头还原。
        if !AppendOnlyStreamCheck.isContinuation(
            of: visibleText,
            previousUTF8Count: seenUTF8Count,
            previousFingerprint: seenFingerprint
        ) {
            self = StreamingNewlineRestorer()
        }
        let utf8Count = visibleText.utf8.count
        seenUTF8Count = utf8Count
        seenFingerprint = AppendOnlyStreamCheck.fingerprint(
            of: visibleText,
            endingAt: utf8Count
        )
        guard utf8Count > consumedUTF8Offset else { return display }

        // consumedUTF8Offset 始终等于上一次完整输入的 UTF-8 长度，必然落在字符边界上。
        let start = visibleText.utf8.index(
            visibleText.utf8.startIndex,
            offsetBy: consumedUTF8Offset
        )
        pendingSource.append(contentsOf: visibleText[start...])
        consumedUTF8Offset = utf8Count

        let settled = settleResolvedPrefix()

        // 待定区按一次性规则渲染，保证流式中途的显示和整段替换的结果逐字符一致。
        let renderedPending = Array(
            TranslationRequestContext.restoreNewlines(from: String(pendingSource))
        )
        display.removeLast(renderedPendingCount)
        display.append(contentsOf: settled)
        display.append(contentsOf: renderedPending)
        renderedPendingCount = renderedPending.count

        return display
    }

    /// 从待定区头部取出已经能确定结果的部分，并把它们从待定区移除。
    private mutating func settleResolvedPrefix() -> [Character] {
        var settled: [Character] = []
        var index = 0

        while index < pendingSource.count {
            let remaining = pendingSource[index...]
            if remaining.starts(with: Self.spacedMarker) {
                settled.append("\n")
                index += Self.spacedMarker.count
                continue
            }
            if remaining.starts(with: Self.bareMarker) {
                settled.append("\n")
                index += Self.bareMarker.count
                continue
            }
            // 还可能是某个标记的前半截（例如 " [[DAZUO_NL]]" 还在等后面那个空格），先留着。
            if Self.isPartialMarker(remaining) {
                break
            }
            settled.append(pendingSource[index])
            index += 1
        }

        pendingSource.removeFirst(index)
        return settled
    }

    private static func isPartialMarker(_ characters: ArraySlice<Character>) -> Bool {
        spacedMarker.starts(with: characters) || bareMarker.starts(with: characters)
    }
}
