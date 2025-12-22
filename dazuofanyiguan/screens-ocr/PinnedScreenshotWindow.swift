import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PinnedScreenshotWindow: NSWindow, NSWindowDelegate {
    private final class MovableHostingView<Content: View>: NSHostingView<Content> {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    final class Model: ObservableObject {
        @Published var isAlwaysOnTop: Bool = true
        @Published var isFocused: Bool = false
    }

    private let model: Model
    private let onRequestClose: () -> Void
    private let onRequestCloseAll: () -> Void

    init(image: NSImage, initialRect: CGRect, onRequestClose: @escaping () -> Void, onRequestCloseAll: @escaping () -> Void) {
        self.model = Model()
        self.onRequestClose = onRequestClose
        self.onRequestCloseAll = onRequestCloseAll

        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // 保持等比例缩放（不拉伸）。
        contentAspectRatio = image.size
        minSize = NSSize(width: 220, height: 140)

        let view = PinnedScreenshotView(
            image: image,
            model: model,
            onClose: { [weak self] in
                self?.close()
            },
            onCloseAll: { [weak self] in
                self?.onRequestCloseAll()
            },
            onToggleAlwaysOnTop: { [weak self] in
                self?.toggleAlwaysOnTop()
            }
        )

        contentView = MovableHostingView(rootView: view)
        makeFirstResponder(contentView)
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func toggleAlwaysOnTop() {
        model.isAlwaysOnTop.toggle()
        level = model.isAlwaysOnTop ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        onRequestClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.isFocused = true
    }

    func windowDidResignKey(_ notification: Notification) {
        model.isFocused = false
    }
}

struct PinnedScreenshotView: View {
    let image: NSImage
    @ObservedObject var model: PinnedScreenshotWindow.Model
    let onClose: () -> Void
    let onCloseAll: () -> Void
    let onToggleAlwaysOnTop: () -> Void

    @State private var isHovering: Bool = false
    @State private var glowOn: Bool = false
    @State private var glowPulseTask: Task<Void, Never>? = nil

    @State private var exportDocument = PNGDocument(data: Data())
    @State private var exportFilename: String = "PinnedScreenshot.png"
    @State private var showExporter: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(6)

            HStack(spacing: 8) {
                Button {
                    onToggleAlwaysOnTop()
                } label: {
                    Image(systemName: model.isAlwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("置顶")

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )
            .opacity((isHovering || model.isFocused) ? 1.0 : 0.0)
        }
        .overlay(
            Rectangle()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.14), lineWidth: 1)
        )
        .overlay(
            Rectangle()
                .strokeBorder(Color.green.opacity(0.9), lineWidth: (model.isAlwaysOnTop && glowOn) ? 2 : 0)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            if model.isAlwaysOnTop {
                startGlowPulse()
            }
        }
        .onChange(of: model.isAlwaysOnTop) { _, enabled in
            if enabled {
                startGlowPulse()
            } else {
                glowPulseTask?.cancel()
                glowPulseTask = nil
                glowOn = false
            }
        }
        .contextMenu {
            Button("复制") {
                copyImageToPasteboard(image)
            }
            Button("保存") {
                prepareExport(image)
            }

            Divider()

            Button("关闭") {
                onClose()
            }
            Button("全部关闭") {
                onCloseAll()
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .png,
            defaultFilename: exportFilename
        ) { _ in }
    }

    private func startGlowPulse() {
        glowPulseTask?.cancel()
        glowPulseTask = Task { @MainActor in
            glowOn = false
            // 只闪两下：2 次“亮->灭”。
            for _ in 0..<2 {
                withAnimation(.easeInOut(duration: 0.42)) {
                    glowOn = true
                }
                try? await Task.sleep(nanoseconds: 420_000_000)
                if Task.isCancelled { return }

                withAnimation(.easeInOut(duration: 0.42)) {
                    glowOn = false
                }
                try? await Task.sleep(nanoseconds: 420_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func copyImageToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = pngData(from: image) {
            pb.setData(data, forType: .png)
        } else {
            pb.writeObjects([image])
        }
    }

    private func prepareExport(_ image: NSImage) {
        guard let data = pngData(from: image) else { return }
        exportDocument = PNGDocument(data: data)

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        exportFilename = "Achord_\(f.string(from: Date()))"

        // 通过状态驱动 fileExporter，避免在菜单回调里直接弹 AppKit 面板。
        DispatchQueue.main.async {
            showExporter = true
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    private struct PNGDocument: FileDocument {
        static var readableContentTypes: [UTType] { [.png] }
        var data: Data

        init(data: Data) {
            self.data = data
        }

        init(configuration: ReadConfiguration) throws {
            self.data = configuration.file.regularFileContents ?? Data()
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: data)
        }
    }
}
