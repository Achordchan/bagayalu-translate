import AppKit
import SwiftUI

struct ScreenshotSelectionView: NSViewRepresentable {
    let onCancel: () -> Void
    let onSelection: (CGRect) -> Void

    func makeNSView(context: Context) -> SelectionNSView {
        let v = SelectionNSView()
        v.onCancel = onCancel
        v.onSelection = onSelection
        return v
    }

    func updateNSView(_ nsView: SelectionNSView, context: Context) {
        nsView.onCancel = onCancel
        nsView.onSelection = onSelection
    }

    final class SelectionNSView: NSView {
        var onCancel: (() -> Void)?
        var onSelection: ((CGRect) -> Void)?

        private var isDragging: Bool = false
        private var startPoint: CGPoint = .zero
        private var currentPoint: CGPoint = .zero

        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            window?.makeFirstResponder(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // ESC
                onCancel?()
                return
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            isDragging = true
            startPoint = convert(event.locationInWindow, from: nil)
            currentPoint = startPoint
            w.makeFirstResponder(self)
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }
            currentPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            isDragging = false
            currentPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true

            let rect = selectionRect().integral
            if rect.width < 8 || rect.height < 8 {
                onCancel?()
                return
            }
            onSelection?(rect)
        }

        private func selectionRect() -> CGRect {
            let x1 = min(startPoint.x, currentPoint.x)
            let x2 = max(startPoint.x, currentPoint.x)
            let y1 = min(startPoint.y, currentPoint.y)
            let y2 = max(startPoint.y, currentPoint.y)
            return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            // 半透明遮罩
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fill(bounds)

            let rect = selectionRect()
            if rect.width > 1, rect.height > 1 {
                // 清出选区（视觉上像“挖洞”）
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.fill(rect)
                ctx.restoreGState()

                // 选区描边
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(rect.insetBy(dx: 1, dy: 1))

                // 边角高亮
                ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(rect.insetBy(dx: 2, dy: 2))
            }
        }
    }
}
