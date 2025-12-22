import AppKit
import SwiftUI

struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        InsetTextView(text: $text, placeholder: placeholder)
    }
}

private struct InsetTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    private final class InterceptingTextView: NSTextView {
        var onMarkedTextStateChanged: ((Bool) -> Void)?
        var onCompositionCommitted: ((String) -> Void)?

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            onMarkedTextStateChanged?(true)
        }

        override func unmarkText() {
            super.unmarkText()
            onMarkedTextStateChanged?(false)
            onCompositionCommitted?(string)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .default

        let textView = InterceptingTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.delegate = context.coordinator
        textView.string = text
        if !text.isEmpty {
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: (text as NSString).length))
        }
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.verticalScroller?.controlSize = .mini

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "清空原文", action: #selector(Coordinator.clearInput(_:)), keyEquivalent: "")
        clearItem.target = context.coordinator
        menu.addItem(clearItem)
        textView.menu = menu

        let placeholderLabel = NSTextField(labelWithString: placeholder)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.systemFont(ofSize: 15)
        placeholderLabel.textColor = NSColor.secondaryLabelColor
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.isHidden = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        scrollView.contentView.addSubview(placeholderLabel)
        context.coordinator.textView = textView
        context.coordinator.placeholderLabel = placeholderLabel

        textView.onMarkedTextStateChanged = { [weak coordinator = context.coordinator, weak textView] _ in
            guard let coordinator else { return }
            coordinator.updatePlaceholderVisibility(text: textView?.string ?? "", textView: textView)
        }

        textView.onCompositionCommitted = { [weak coordinator = context.coordinator, weak textView] committed in
            coordinator?.commitComposedText(committed, textView: textView)
        }

        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: textView.textContainerInset.width + 10),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: textView.textContainerInset.height + 1)
        ])

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor

        context.coordinator.placeholderLabel?.stringValue = placeholder

        if textView.hasMarkedText() {
            context.coordinator.updatePlaceholderVisibility(text: textView.string, textView: textView)
            return
        }

        if textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            textView.string = text
            if let paragraphStyle = textView.defaultParagraphStyle, !text.isEmpty {
                textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: (text as NSString).length))
            }
            context.coordinator.isProgrammaticUpdate = false
        }
        context.coordinator.updatePlaceholderVisibility(text: text, textView: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: InsetTextView
        weak var textView: NSTextView?
        weak var placeholderLabel: NSTextField?

        var isProgrammaticUpdate: Bool = false

        init(parent: InsetTextView) {
            self.parent = parent
        }

        @objc
        func clearInput(_ sender: Any?) {
            if let tv = textView {
                isProgrammaticUpdate = true
                tv.string = ""
                isProgrammaticUpdate = false
                updatePlaceholderVisibility(text: "", textView: tv)
                tv.window?.makeFirstResponder(tv)
            }
            parent.text = ""
        }

        func updatePlaceholderVisibility(text: String, textView: NSTextView?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let composing = textView?.hasMarkedText() ?? false
            placeholderLabel?.isHidden = composing || !trimmed.isEmpty
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if isProgrammaticUpdate {
                return
            }

            if tv.hasMarkedText() {
                updatePlaceholderVisibility(text: tv.string, textView: tv)
                return
            }

            let newValue = tv.string
            updatePlaceholderVisibility(text: newValue, textView: tv)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.text = newValue
            }
        }

        func commitComposedText(_ text: String, textView: NSTextView?) {
            updatePlaceholderVisibility(text: text, textView: textView)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.text = text
            }
        }
    }
}
