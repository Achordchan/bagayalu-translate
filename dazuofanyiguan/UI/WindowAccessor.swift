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

extension View {
    /// 让承载这个视图的 sheet 不再拦截应用退出。
    ///
    /// AppKit 默认：窗口上挂着 sheet 时，Cmd+Q、注销关机、系统设置的「退出并重新打开」
    /// 这些退出请求都会被直接拦下，连 `applicationShouldTerminate` 都不问
    /// （日志里是 `App termination blocked by modal sheet`）。
    ///
    /// 系统设置授权屏幕录制后，「退出并重新打开」发的是不等回复的 `aevt/quit`，
    /// 固定 3 秒后再按 bundle ID 打开应用。退出被拦下时，3 秒后那次「打开」
    /// 只是把原进程激活一下，看起来就是按钮没反应。
    ///
    /// 只给没有未保存内容的纯展示 sheet 用（权限引导、功能推荐）。
    func allowsAppTerminationWhilePresented() -> some View {
        background(
            WindowAccessor { window in
                window?.preventsApplicationTerminationWhenModal = false
            }
            .frame(width: 0, height: 0)
        )
    }
}
