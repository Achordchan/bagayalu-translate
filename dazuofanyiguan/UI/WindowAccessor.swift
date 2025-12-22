import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    private final class HostingView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            onResolve?(newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = HostingView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HostingView)?.onResolve = onResolve
    }
}
