import SwiftUI

/// 让「打开输入增强测试」这个按钮能从设置页把测试窗口叫出来。
///
/// `openWindow` 只能在 View 里拿到，而按钮在设置面板深处，
/// 所以走一次通知把它接出来。
private struct InputAssistTestWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .dazuofanyiguanOpenInputAssistTest)
        ) { _ in
            openWindow(id: "inputAssistTest")
        }
    }
}

extension View {
    func inputAssistTestWindowOpener() -> some View {
        modifier(InputAssistTestWindowOpener())
    }
}
