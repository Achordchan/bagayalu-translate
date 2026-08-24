import AppKit
import SwiftUI

@MainActor
final class CandidatePanelModel: ObservableObject {
    @Published var state = CandidateListState(languageCodes: [])
    @Published var showsDebugInfo = false
    @Published var showsCacheBadge = true
    /// 每行预留几行文字。浮层出现时从原文估算一次，之后不再变（PRD §12.2）。
    @Published var reservedLineCount = 1

    var onCommitRow: ((Int) -> Void)?
    var onRetryRow: ((Int) -> Void)?
}

/// 候选浮层的视觉。
///
/// 目标是「像 macOS 原生输入法候选窗」而不是「像一个翻译 App 的卡片」（PRD §11.2）：
/// 半透明 HUD 底、原生字体、紧凑语言码、无 Logo、无品牌色。
/// 视觉参数参考 luke-chang/MacishType 的候选窗（MIT）。
struct CandidatePanelView: View {
    @ObservedObject var model: CandidatePanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: CandidatePanelLayout.rowSpacing) {
            ForEach(Array(model.state.rows.enumerated()), id: \.element.id) { index, row in
                CandidateRowView(
                    row: row,
                    isSelected: index == model.state.selectedIndex,
                    reservedLineCount: model.reservedLineCount,
                    showsDebugInfo: model.showsDebugInfo,
                    showsCacheBadge: model.showsCacheBadge,
                    commandIndex: index < 6 ? index + 1 : nil
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    switch row.state {
                    case .failed, .languagePackRequired:
                        model.onRetryRow?(index)
                    case .loading, .translated:
                        model.onCommitRow?(index)
                    }
                }
            }
        }
        .padding(.horizontal, CandidatePanelLayout.horizontalPadding)
        .padding(.vertical, CandidatePanelLayout.verticalPadding)
        .frame(width: CandidatePanelLayout.width, alignment: .leading)
    }
}

private struct CandidateRowView: View {
    let row: CandidateRow
    let isSelected: Bool
    let reservedLineCount: Int
    let showsDebugInfo: Bool
    let showsCacheBadge: Bool
    let commandIndex: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.displayCode)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: CandidatePanelLayout.languageColumnWidth, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                content
                if showsDebugInfo, let debugText {
                    Text(debugText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if showsCacheBadge, isCacheHit {
                Text("⚡")
                    .font(.system(size: 10))
                    .help(cacheBadgeHelp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, CandidatePanelLayout.rowVerticalPadding)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
    }

    @ViewBuilder
    private var content: some View {
        switch row.state {
        case .loading:
            CandidateSkeletonView()

        case .translated(let text, _, _, _):
            // 超出预留高度的部分按 PRD §13.1 用 … 截断，
            // 绝不让它把浮层撑高——高度在弹出时就定死了。
            Text(text)
                .font(.system(size: 13))
                .lineLimit(CandidatePanelLayout.lineCount(
                    reservedLineCount: reservedLineCount,
                    isSelected: isSelected
                ))
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            HStack(spacing: 4) {
                Text("翻译失败")
                    .font(.system(size: 13))
                Text("点击重试")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .help(message)

        case .languagePackRequired:
            HStack(spacing: 4) {
                Text("需要下载语言包")
                    .font(.system(size: 13))
                Text("点击下载")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isCacheHit: Bool {
        guard case .translated(_, let source, _, _) = row.state else { return false }
        return source == .cache
    }

    /// ⚡ 的 hover 提示（PRD §22）。
    private var cacheBadgeHelp: String {
        guard case .translated(_, _, let latency, let engineTitle) = row.state else {
            return "本地缓存命中"
        }
        return "本地缓存命中\n引擎：\(engineTitle)\n响应：\(latency)ms"
    }

    /// ⌥ 按住时的调试信息（PRD §23）。
    private var debugText: String? {
        switch row.state {
        case .translated(_, let source, let latency, let engineTitle):
            return source == .cache
                ? "\(engineTitle) · Cache · \(latency)ms"
                : "\(engineTitle) · \(latency)ms · Network"
        case .failed(let message):
            return message
        case .languagePackRequired:
            return "Apple Translation · language pack missing"
        case .loading:
            return nil
        }
    }
}

/// 骨架条（PRD §12.1）。刻意做成静态灰条：PRD §11.2 不要夸张动画。
private struct CandidateSkeletonView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 10)
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.vertical, 4)
    }
}

/// HUD 材质底。原生候选窗那种半透明质感来自 `.hudWindow` + `.behindWindow`，
/// 用普通填充色做不出来。
private struct CandidatePanelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 承载候选视图的浮层。
///
/// `.nonactivatingPanel` + `canBecomeKey = false`：**绝不抢原 App 的焦点**（PRD §14.1）。
/// 也正因为不抢焦点，按键必须靠 `CandidateKeyTap` 拦截，而不是靠窗口自己收键盘事件。
@MainActor
final class CandidatePanel: NSPanel {
    init(model: CandidatePanelModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: CandidatePanelLayout.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isExcludedFromWindowsMenu = true

        contentView = NSHostingView(
            rootView: ZStack {
                CandidatePanelBackdrop()
                CandidatePanelView(model: model)
            }
        )
    }

    /// 永远不做 key window：用户的输入焦点必须留在原文本控件里。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system: self.appearance = nil
        case .light: self.appearance = NSAppearance(named: .aqua)
        case .dark: self.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func present(anchorRect: CGRect, contentSize: CGSize) {
        setContentSize(contentSize)

        let anchorPoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        guard let screen = CandidatePanelPositioner.screen(containing: anchorPoint) else {
            center()
            orderFrontRegardless()
            return
        }

        let origin = CandidatePanelPositioner.panelOrigin(
            anchorRect: anchorRect,
            panelSize: contentSize,
            visibleFrame: screen.visibleFrame
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}
