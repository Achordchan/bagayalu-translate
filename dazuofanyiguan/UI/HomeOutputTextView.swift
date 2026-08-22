import AppKit
import SwiftUI

struct OutputTextView: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .default

        let textView = NSTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: CGFloat(fontSize))
        textView.textColor = NSColor.labelColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.string = text
        if !text.isEmpty {
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: (text as NSString).length))
        }
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.verticalScroller?.controlSize = .mini
        context.coordinator.markApplied(text)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let size = CGFloat(fontSize)
        if abs((textView.font?.pointSize ?? 0) - size) > 0.01 {
            let font = NSFont.systemFont(ofSize: size)
            textView.font = font
            textView.typingAttributes[.font] = font
            let length = textView.textStorage?.length ?? 0
            if length > 0 {
                textView.textStorage?.addAttribute(
                    .font,
                    value: font,
                    range: NSRange(location: 0, length: length)
                )
            }
        }
        applyText(to: textView, coordinator: context.coordinator)
    }

    /// 流式翻译时这里每收到一个 delta 就会被调用一次。
    /// 整段替换 textView.string 会丢弃全部排版并重新计算，代价随译文长度呈二次增长，
    /// 还会重置滚动位置和用户选区；因此纯追加的情况只把新增部分写进 textStorage。
    private func applyText(to textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.appliedText != text else { return }

        let paragraphStyle = textView.defaultParagraphStyle
        defer { coordinator.markApplied(text) }

        if coordinator.appliedUTF8Count > 0,
           AppendOnlyStreamCheck.isContinuation(
               of: text,
               previousUTF8Count: coordinator.appliedUTF8Count,
               previousFingerprint: coordinator.appliedFingerprint
           ),
           let textStorage = textView.textStorage {
            let appended = text[
                text.utf8.index(text.utf8.startIndex, offsetBy: coordinator.appliedUTF8Count)...
            ]
            var attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.systemFont(ofSize: CGFloat(fontSize)),
                .foregroundColor: NSColor.labelColor
            ]
            if let paragraphStyle {
                attributes[.paragraphStyle] = paragraphStyle
            }
            textStorage.append(
                NSAttributedString(string: String(appended), attributes: attributes)
            )
            return
        }

        textView.string = text
        if let paragraphStyle, !text.isEmpty {
            textView.textStorage?.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: (text as NSString).length)
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        /// 已经写进 textView 的文本。直接读 textView.string 每次都要做一遍 NSString 桥接。
        private(set) var appliedText = ""
        /// 长度与结尾指纹用于 O(1) 判断「是不是纯追加」。
        /// String.hasPrefix 会走 Unicode 规范化比较，放在每个 delta 上会重新变成瓶颈。
        private(set) var appliedUTF8Count = 0
        private(set) var appliedFingerprint: [UInt8] = []

        func markApplied(_ text: String) {
            appliedText = text
            appliedUTF8Count = text.utf8.count
            appliedFingerprint = AppendOnlyStreamCheck.fingerprint(
                of: text,
                endingAt: appliedUTF8Count
            )
        }
    }
}
