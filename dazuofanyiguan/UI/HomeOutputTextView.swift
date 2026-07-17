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
        if textView.string != text {
            textView.string = text
            if let paragraphStyle = textView.defaultParagraphStyle, !text.isEmpty {
                textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: (text as NSString).length))
            }
        }
    }
}
