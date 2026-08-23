import AppKit
import Foundation

/// 剪贴板快照 / 恢复（参考 TypeTide `Pasteboard.swift`，MIT）。
///
/// 必须按 `item.types` 逐类型深拷贝：只存 `string(forType:)` 的话，
/// 用户剪贴板里原本的图片、富文本、文件引用在 fallback 之后就没了。
enum InputAssistPasteboardSnapshot {
    static func snapshot(from pasteboard: NSPasteboard = .general) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
