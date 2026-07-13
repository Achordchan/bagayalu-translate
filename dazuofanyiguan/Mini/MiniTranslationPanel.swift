import AppKit
import SwiftUI

enum MiniTranslationBubbleState: Equatable {
    case translating
    case result(String)
    case error(String)
}

enum MiniTranslationIcon {
    static let enabled = "text.bubble.fill"
    static let disabled = "text.bubble"
}

@MainActor
final class MiniTranslationBubbleModel: ObservableObject {
    @Published var state: MiniTranslationBubbleState = .translating

    var onDismiss: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
}

struct MiniTranslationLayout {
    static func contentSize(for state: MiniTranslationBubbleState) -> NSSize {
        switch state {
        case .translating:
            return NSSize(width: 300, height: 78)
        case .error(let message):
            let lines = estimatedLineCount(for: message, charactersPerLine: 30, maximum: 5)
            return NSSize(width: 420, height: max(130, CGFloat(110 + lines * 19)))
        case .result(let text):
            let lines = estimatedLineCount(for: text, charactersPerLine: 34, maximum: 11)
            return NSSize(width: 460, height: min(340, max(160, CGFloat(118 + lines * 20))))
        }
    }

    private static func estimatedLineCount(
        for text: String,
        charactersPerLine: Int,
        maximum: Int
    ) -> Int {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = paragraphs.reduce(into: 0) { total, paragraph in
            let wrappedLines = max(
                1,
                Int(ceil(Double(paragraph.count) / Double(charactersPerLine)))
            )
            total += wrappedLines
        }
        return max(1, min(maximum, lines))
    }

    static func bubbleOrigin(
        anchor: CGPoint,
        contentSize: NSSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let margin: CGFloat = 12
        let pointerGap: CGFloat = 14

        var x = anchor.x + pointerGap
        if x + contentSize.width > visibleFrame.maxX - margin {
            x = anchor.x - contentSize.width - pointerGap
        }

        var y = anchor.y - contentSize.height - pointerGap
        if y < visibleFrame.minY + margin {
            y = anchor.y + pointerGap
        }

        x = min(
            max(x, visibleFrame.minX + margin),
            visibleFrame.maxX - contentSize.width - margin
        )
        y = min(
            max(y, visibleFrame.minY + margin),
            visibleFrame.maxY - contentSize.height - margin
        )

        return CGPoint(x: x, y: y)
    }
}

@MainActor
final class MiniTranslationPanel: NSPanel {
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }

    private let model: MiniTranslationBubbleModel
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(model: MiniTranslationBubbleModel) {
        self.model = model

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 78),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        isMovable = true

        contentView = FirstMouseHostingView(
            rootView: MiniTranslationBubbleView(model: model)
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            self.appearance = nil
        case .light:
            self.appearance = NSAppearance(named: .aqua)
        case .dark:
            self.appearance = NSAppearance(named: .darkAqua)
        }
    }

    override func orderOut(_ sender: Any?) {
        stopOutsideClickMonitoring()
        super.orderOut(sender)
    }

    func present(near anchor: CGPoint, contentSize: NSSize) {
        setContentSize(contentSize)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            center()
            orderFrontRegardless()
            startOutsideClickMonitoring()
            return
        }

        let origin = MiniTranslationLayout.bubbleOrigin(
            anchor: anchor,
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
        startOutsideClickMonitoring()
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismissIfClickIsOutside()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.dismissIfClickIsOutside()
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func dismissIfClickIsOutside() {
        guard isVisible, !frame.contains(NSEvent.mouseLocation) else {
            return
        }
        model.onDismiss?()
    }
}

private struct MiniTranslationBubbleView: View {
    @ObservedObject var model: MiniTranslationBubbleModel
    @Environment(\.colorScheme) private var colorScheme

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: shadowColor, radius: 16, x: 0, y: 6)
        .padding(6)
        .onHover { hovering in
            model.onHoverChange?(hovering)
        }
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.07)
    }

    private var shadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.42)
            : Color.black.opacity(0.13)
    }

    private var header: some View {
        ZStack {
            MiniTranslationDragHandle()

            HStack(spacing: 8) {
                statusIcon
                statusTitle
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
        .help("拖动标题可移动窗口")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.state {
        case .translating:
            ProgressView()
                .controlSize(.small)
        case .result:
            Image(systemName: MiniTranslationIcon.enabled)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusTitle: some View {
        switch model.state {
        case .translating:
            title("正在翻译")
        case .result:
            title("翻译结果")
        case .error:
            title("翻译失败")
        }
    }

    private func title(_ status: String) -> some View {
        HStack(spacing: 5) {
            Text(status)
                .font(.system(size: 13, weight: .semibold))

            Text("· 大佐翻译官 v\(appVersion)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .translating:
            EmptyView()
        case .result(let text):
            MiniTranslationResultView(text: text)
                .help("拖动选择文字后按 Command+C 复制")
        case .error(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MiniTranslationDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}

private struct MiniTranslationScrollMetrics: Equatable {
    var offsetY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
}

private struct MiniTranslationResultView: View {

    let text: String

    @State private var scrollMetrics = MiniTranslationScrollMetrics()
    @State private var isHovering = false

    var body: some View {
        MiniSelectableTranslationTextView(
            text: text,
            metrics: $scrollMetrics
        )
        .padding(.trailing, showsScrollIndicator ? 10 : 0)
        .overlay(alignment: .trailing) {
            if showsScrollIndicator {
                GeometryReader { geometry in
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.28 : 0.16))
                        .frame(width: 3.5, height: thumbHeight(for: geometry.size.height))
                        .offset(y: thumbOffset(for: geometry.size.height))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 1)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var showsScrollIndicator: Bool {
        scrollMetrics.contentHeight > scrollMetrics.viewportHeight + 1
    }

    private func thumbHeight(for availableHeight: CGFloat) -> CGFloat {
        guard scrollMetrics.contentHeight > 0 else {
            return availableHeight
        }
        return max(
            28,
            availableHeight * scrollMetrics.viewportHeight / scrollMetrics.contentHeight
        )
    }

    private func thumbOffset(for availableHeight: CGFloat) -> CGFloat {
        let height = thumbHeight(for: availableHeight)
        let scrollableContent = max(1, scrollMetrics.contentHeight - scrollMetrics.viewportHeight)
        let progress = min(max(scrollMetrics.offsetY / scrollableContent, 0), 1)
        return progress * max(0, availableHeight - height)
    }
}

private struct MiniSelectableTranslationTextView: NSViewRepresentable {
    let text: String
    @Binding var metrics: MiniTranslationScrollMetrics

    func makeNSView(context: Context) -> ScrollContainer {
        let container = ScrollContainer()
        container.onMetricsChange = { newMetrics in
            if metrics != newMetrics {
                metrics = newMetrics
            }
        }
        container.setText(text)
        return container
    }

    func updateNSView(_ nsView: ScrollContainer, context: Context) {
        nsView.onMetricsChange = { newMetrics in
            if metrics != newMetrics {
                metrics = newMetrics
            }
        }
        nsView.setText(text)
    }

    final class ScrollContainer: NSView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        var onMetricsChange: ((MiniTranslationScrollMetrics) -> Void)?

        private var currentText = ""
        private var boundsObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureViews()
        }

        required init?(coder: NSCoder) {
            nil
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        override func layout() {
            super.layout()
            scrollView.frame = bounds
            updateDocumentLayout()
        }

        func setText(_ text: String) {
            guard currentText != text else {
                return
            }

            currentText = text
            textView.textStorage?.setAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: Self.textAttributes
                )
            )
            needsLayout = true
        }

        private func configureViews() {
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true

            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.minSize = .zero
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.autoresizingMask = [.width]

            scrollView.documentView = textView
            addSubview(scrollView)

            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.publishMetrics()
            }
        }

        private func updateDocumentLayout() {
            let viewportSize = scrollView.contentSize
            guard viewportSize.width > 0, viewportSize.height > 0 else {
                return
            }

            textView.textContainer?.containerSize = NSSize(
                width: viewportSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)

            let textHeight = textView.layoutManager.map {
                ceil($0.usedRect(for: textView.textContainer!).height)
            } ?? 0
            let documentHeight = max(viewportSize.height, textHeight)

            textView.setFrameSize(
                NSSize(width: viewportSize.width, height: documentHeight)
            )
            publishMetrics()
        }

        private func publishMetrics() {
            let viewportHeight = scrollView.contentSize.height
            let contentHeight = textView.frame.height
            let maximumOffset = max(0, contentHeight - viewportHeight)
            let offsetY = min(
                max(scrollView.contentView.bounds.origin.y, 0),
                maximumOffset
            )

            onMetricsChange?(
                MiniTranslationScrollMetrics(
                    offsetY: offsetY,
                    contentHeight: contentHeight,
                    viewportHeight: viewportHeight
                )
            )
        }

        private static var textAttributes: [NSAttributedString.Key: Any] {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4

            return [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        }
    }
}
