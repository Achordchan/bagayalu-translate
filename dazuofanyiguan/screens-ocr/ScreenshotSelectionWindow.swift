import AppKit
import SwiftUI

@MainActor
final class ScreenshotSelectionWindow: NSWindow {
    private final class AcceptsFirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }

    private let session: ScreenshotOCRSession
    private let onCancel: () -> Void
    private let onSelectionConfirmed: (CGRect) -> Void
    private let onTranslateTapped: () -> Void
    private let onExtractTapped: () -> Void
    private let onPinTapped: () -> Void
    private let onFinishTapped: () -> Void

    init(
        session: ScreenshotOCRSession,
        onCancel: @escaping () -> Void,
        onSelectionConfirmed: @escaping (CGRect) -> Void,
        onTranslateTapped: @escaping () -> Void,
        onExtractTapped: @escaping () -> Void,
        onPinTapped: @escaping () -> Void,
        onFinishTapped: @escaping () -> Void
    ) {
        self.session = session
        self.onCancel = onCancel
        self.onSelectionConfirmed = onSelectionConfirmed
        self.onTranslateTapped = onTranslateTapped
        self.onExtractTapped = onExtractTapped
        self.onPinTapped = onPinTapped
        self.onFinishTapped = onFinishTapped

        let frame = ScreenshotSelectionWindow.fullVirtualScreenFrame()

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        let root = ScreenshotSelectionWorkspaceView(
            session: session,
            onCancel: { [weak self] in
                self?.onCancel()
            },
            onSelectionConfirmed: { [weak self] rectInContent in
                guard let self else { return }
                self.onSelectionConfirmed(rectInContent)
            },
            onTranslateTapped: { [weak self] in
                self?.onTranslateTapped()
            },
            onExtractTapped: { [weak self] in
                self?.onExtractTapped()
            },
            onPinTapped: { [weak self] in
                self?.onPinTapped()
            },
            onFinishTapped: { [weak self] in
                self?.onFinishTapped()
            }
        )

        contentView = AcceptsFirstMouseHostingView(rootView: root)
        makeFirstResponder(contentView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键逻辑：
        // - 已有选区：清空选区，回到重新框选状态。
        // - 没有选区：退出截图翻译。
        if session.selectionRect.width > 1, session.selectionRect.height > 1 {
            session.selectionRect = .zero
            session.stage = .selecting
            session.ocrText = ""
            session.translatedText = ""
            session.ocrLines = []
            session.translatedLines = []
            session.capturedImage = nil
            session.showCompare = false
            return
        }

        onCancel()
    }

    func selectionRectInScreen() -> CGRect {
        // session.selectionRect 是 contentView 坐标（左下原点），可以直接用于 convertToScreen。
        convertToScreen(session.selectionRect)
    }

    static func fullVirtualScreenFrame() -> CGRect {
        let frames = NSScreen.screens.map { $0.frame }
        guard var union = frames.first else { return .zero }
        for f in frames.dropFirst() {
            union = union.union(f)
        }
        return union
    }
}
