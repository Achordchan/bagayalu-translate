import SwiftUI

/// 让「打开选区翻译测试」从设置页叫出测试窗口。
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
