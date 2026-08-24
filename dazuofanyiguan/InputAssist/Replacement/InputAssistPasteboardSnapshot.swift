import AppKit
import Foundation

/// 按类型深拷贝剪贴板，避免丢失图片、富文本或文件引用。
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
