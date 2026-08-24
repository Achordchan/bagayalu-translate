import AppKit
import SwiftUI

private struct InputAssistFeedbackView: View {
    let message: String
    let systemImage: String

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }
}

/// 在原选区附近显示短暂反馈，不抢目标 App 焦点。
@MainActor
final class InputAssistFeedbackPanelController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(
        message: String,
        systemImage: String,
        anchorRect: CGRect,
        appearance: AppAppearance?
    ) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let size = CGSize(width: 300, height: 38)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        switch appearance {
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .system, nil: panel.appearance = nil
        }
        panel.contentView = NSHostingView(
            rootView: InputAssistFeedbackView(message: message, systemImage: systemImage)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        )

        let anchorPoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        if let screen = CandidatePanelPositioner.screen(containing: anchorPoint) {
            panel.setFrameOrigin(
                CandidatePanelPositioner.panelOrigin(
                    anchorRect: anchorRect,
                    panelSize: size,
                    visibleFrame: screen.visibleFrame
                )
            )
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            if self?.panel === panel {
                self?.panel = nil
            }
        }
    }
}
