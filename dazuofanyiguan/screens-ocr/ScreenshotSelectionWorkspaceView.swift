import AppKit
import SwiftUI

struct ScreenshotSelectionWorkspaceView: View {
    @ObservedObject var session: ScreenshotOCRSession

    @Environment(\.colorScheme) private var colorScheme

    let onCancel: () -> Void
    let onSelectionConfirmed: (CGRect) -> Void
    let onTranslateTapped: () -> Void
    let onExtractTapped: () -> Void
    let onPinTapped: () -> Void
    let onFinishTapped: () -> Void

    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    @State private var showOCRInfo: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if !session.frozenBackgrounds.isEmpty {
                    frozenBackgroundView(size: geo.size)
                }
                maskView(size: geo.size)

                if session.selectionRect.width > 1, session.selectionRect.height > 1 {
                    selectionBorder(size: geo.size)
                    selectionContent(size: geo.size)
                    if session.stage != .selecting {
                        toolbar(size: geo.size)
                    }
                } else {
                    hint
                        .padding(.top, 18)
                        .padding(.leading, 18)
                }

                if let toast = session.hudToast,
                   session.selectionRect.width > 1,
                   session.selectionRect.height > 1,
                   session.stage != .selecting {
                    let rectTopLeft = rectToTopLeft(rectBottomLeft: session.selectionRect, containerSize: geo.size)
                    let p = hudToastPosition(containerSize: geo.size, selectionRectTopLeft: rectTopLeft)
                    hudToastView(toast)
                        .position(x: p.x, y: p.y)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .gesture(session.stage == .selecting ? dragGesture(size: geo.size) : nil)
        }
    }

    private func frozenBackgroundView(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.frozenBackgrounds) { item in
                let rectTopLeft = rectToTopLeft(rectBottomLeft: item.rect, containerSize: size)
                Image(nsImage: item.image)
                    .resizable()
                    .frame(width: rectTopLeft.width, height: rectTopLeft.height)
                    .position(x: rectTopLeft.midX, y: rectTopLeft.midY)
            }
        }
        .ignoresSafeArea()
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拖拽选择要翻译的区域")
                .font(.system(size: 16, weight: .bold))
            Text("松开鼠标后会先缓存截图。点击“翻译”才会进行 OCR + 翻译。按 Esc 取消；右键：有选区清空，无选区退出。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .dsCard()
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? value.startLocation
                dragStart = start
                dragCurrent = value.location

                let rectTopLeft = normalizedRectTopLeft(start: start, current: value.location)
                session.selectionRect = rectToBottomLeft(rectTopLeft: rectTopLeft, containerSize: size)
                session.stage = .selecting
            }
            .onEnded { _ in
                defer {
                    dragStart = nil
                    dragCurrent = nil
                }

                let rect = session.selectionRect.integral
                if rect.width < 8 || rect.height < 8 {
                    session.selectionRect = .zero
                    session.stage = .selecting
                    return
                }

                session.selectionRect = rect
                session.stage = .selected
                onSelectionConfirmed(rect)
            }
    }

    private func maskView(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let full = Path(CGRect(origin: .zero, size: canvasSize))
            context.fill(full, with: .color(Color.black.opacity(0.35)))

            if session.selectionRect.width > 1, session.selectionRect.height > 1 {
                let rectTopLeft = rectToTopLeft(rectBottomLeft: session.selectionRect, containerSize: canvasSize)
                var hole = Path()
                hole.addRoundedRect(in: rectTopLeft, cornerSize: CGSize(width: 10, height: 10))
                context.blendMode = .clear
                context.fill(hole, with: .color(.black))
                context.blendMode = .normal
            }
        }
        .ignoresSafeArea()
    }

    private func selectionBorder(size: CGSize) -> some View {
        let rectTopLeft = rectToTopLeft(rectBottomLeft: session.selectionRect, containerSize: size)
        let rect = displayRectTopLeft(baseRectTopLeft: rectTopLeft, containerSize: size)

        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                    .padding(1)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func selectionContent(size: CGSize) -> some View {
        let rectTopLeft = rectToTopLeft(rectBottomLeft: session.selectionRect, containerSize: size)
        let rect = displayRectTopLeft(baseRectTopLeft: rectTopLeft, containerSize: size)
        let isCompare = session.showCompare && session.stage == .translated

        return ZStack(alignment: .topLeading) {
            if isCompare {
                compareInlineOverlay
            } else if session.stage == .translated {
                if !session.translatedLines.isEmpty {
                    lineOverlays(lines: session.translatedLines, selectionSize: rect.size)
                } else {
                    overlayText(text: session.translatedText)
                }
            } else if session.stage == .translating {
                if !session.translatedLines.isEmpty {
                    lineOverlays(lines: session.translatedLines, selectionSize: rect.size)
                } else {
                    overlayText(text: session.translatedText)
                }
            } else if session.stage == .ocrReady {
                if !session.ocrLines.isEmpty {
                    lineOverlays(lines: session.ocrLines, selectionSize: rect.size)
                } else {
                    overlayText(text: session.ocrText)
                }
            } else if case .failed(let message) = session.stage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("出错了")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("你可以重新框选一次，或者调整源语言后再试。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
            } else if session.stage == .ocrRunning {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在识别文字…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    if !session.ocrText.isEmpty {
                        Text(session.ocrText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func lineOverlays(lines: [VisionOCRService.OCRLine], selectionSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // 整体轻背景，保证覆盖可读。
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                )

            ForEach(lines) { line in
                let rect = lineRect(line.boundingBox, selectionSize: selectionSize)
                let fontSize = clampFontSize(rect.height >= 28 ? rect.height * 0.45 : rect.height * 0.82)

                Text(line.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func lineRect(_ boundingBox: CGRect, selectionSize: CGSize) -> CGRect {
        // boundingBox：0~1，左下原点。
        // SwiftUI inside selectionContent：左上原点。
        let x = boundingBox.minX * selectionSize.width
        let y = (1 - boundingBox.maxY) * selectionSize.height
        let w = boundingBox.width * selectionSize.width
        let h = boundingBox.height * selectionSize.height
        return CGRect(x: x, y: y, width: max(8, w), height: max(10, h))
    }

    private func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, 11), 22)
    }

    private func overlayText(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
    }

    private var compareInlineOverlay: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("原文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(session.ocrText)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.blue.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1))
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 8) {
                Text("译文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(session.translatedText)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
    }

    private func toolbar(size: CGSize) -> some View {
        let rectTopLeft = rectToTopLeft(rectBottomLeft: session.selectionRect, containerSize: size)
        let proposed = toolbarPosition(containerSize: size, selectionRectTopLeft: rectTopLeft)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LanguageSearchPicker(
                    title: "源",
                    allowAuto: false,
                    options: LanguagePreset.screenshotSource,
                    selection: $session.sourceLanguageCode,
                    fixedWidth: 170
                )

                LanguageSearchPicker(
                    title: "目标",
                    allowAuto: false,
                    options: LanguagePreset.common,
                    selection: $session.targetLanguageCode,
                    fixedWidth: 170
                )

                Spacer(minLength: 0)

                Button {
                    onPinTapped()
                } label: {
                    Image(systemName: "pin.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("钉到屏幕")

                Button {
                    showOCRInfo.toggle()
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("关于截图 OCR")
                .popover(isPresented: $showOCRInfo, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("关于截图 OCR")
                            .font(.system(size: 14, weight: .bold))

                        Text("本功能使用 Apple Vision（本地免费 OCR）进行文字识别。")
                            .font(.system(size: 13, weight: .medium))

                        Text("免费 OCR 的准确度会受截图清晰度、字体、背景、语言等影响，可能出现漏字/错字/断行。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text("更推荐：优先用 Cmd+C+C（复制文字翻译），通常更稳定、更准确。")
                            .font(.system(size: 13, weight: .semibold))

                        Divider()

                        Text("小技巧：右键可清空选区或退出。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(width: 320)
                }
            }

            HStack(spacing: 10) {
                Toggle("对照", isOn: $session.showCompare)
                    .toggleStyle(SwitchToggleStyle())
                    .controlSize(.mini)
                    .disabled(session.stage != .translated)

                Button {
                    onExtractTapped()
                } label: {
                    Label("提取原文", systemImage: "text.viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(!canExtract)

                Button {
                    onTranslateTapped()
                } label: {
                    Label(translateButtonTitle, systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(!canTranslate)

                Button {
                    onFinishTapped()
                } label: {
                    Label("完成", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }


                Spacer(minLength: 0)

                if session.stage == .ocrRunning || session.stage == .translating {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(12)
        // 工具栏外观要跟随主程序深色主题：使用系统 Material（自动适配深浅色），
        // 只保留轻描边与更克制的阴影。
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.75 : 0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.14), radius: colorScheme == .dark ? 18 : 14, x: 0, y: 10)
        .frame(width: 420)
        .position(x: proposed.x, y: proposed.y)
    }

    private func copyToPasteboard(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
    }

    private var canTranslate: Bool {
        switch session.stage {
        case .selected:
            return session.capturedImage != nil
        case .ocrReady, .translated:
            return !session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .translating, .ocrRunning:
            return false
        default:
            return false
        }
    }

    private var canExtract: Bool {
        switch session.stage {
        case .selected:
            return session.capturedImage != nil
        case .ocrReady, .translated:
            return true
        case .translating, .ocrRunning:
            return false
        default:
            return false
        }
    }

    private var translateButtonTitle: String {
        switch session.stage {
        case .ocrRunning:
            return "识别中…"
        case .translating:
            return "正在翻译…"
        case .translated:
            return "重新翻译"
        default:
            return "翻译"
        }
    }

    private func toolbarPosition(containerSize: CGSize, selectionRectTopLeft: CGRect) -> CGPoint {
        // 这里用一个“可用空间优先级”策略：
        // 右侧优先，其次左侧，其次上方，其次下方。
        // 目标是尽量不遮挡选框内容。
        let toolbarSize = CGSize(width: 420, height: 118)
        let margin: CGFloat = 12

        let rightSpace = containerSize.width - selectionRectTopLeft.maxX - margin
        let leftSpace = selectionRectTopLeft.minX - margin
        let topSpace = selectionRectTopLeft.minY - margin

        let yAligned = clamp(selectionRectTopLeft.minY + 18, min: 60, max: containerSize.height - 60)

        if rightSpace >= toolbarSize.width {
            let x = clamp(selectionRectTopLeft.maxX + margin + toolbarSize.width / 2, min: toolbarSize.width / 2 + margin, max: containerSize.width - toolbarSize.width / 2 - margin)
            return CGPoint(x: x, y: yAligned)
        }
        if leftSpace >= toolbarSize.width {
            let x = clamp(selectionRectTopLeft.minX - margin - toolbarSize.width / 2, min: toolbarSize.width / 2 + margin, max: containerSize.width - toolbarSize.width / 2 - margin)
            return CGPoint(x: x, y: yAligned)
        }
        if topSpace >= toolbarSize.height {
            let x = clamp(selectionRectTopLeft.midX, min: toolbarSize.width / 2 + margin, max: containerSize.width - toolbarSize.width / 2 - margin)
            let y = clamp(selectionRectTopLeft.minY - margin - toolbarSize.height / 2, min: toolbarSize.height / 2 + margin, max: containerSize.height - toolbarSize.height / 2 - margin)
            return CGPoint(x: x, y: y)
        }
        // bottom fallback
        let x = clamp(selectionRectTopLeft.midX, min: toolbarSize.width / 2 + margin, max: containerSize.width - toolbarSize.width / 2 - margin)
        let y = clamp(selectionRectTopLeft.maxY + margin + toolbarSize.height / 2, min: toolbarSize.height / 2 + margin, max: containerSize.height - toolbarSize.height / 2 - margin)
        return CGPoint(x: x, y: y)
    }

    private func clamp(_ v: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        if v < min { return min }
        if v > max { return max }
        return v
    }

    private func displayRectTopLeft(baseRectTopLeft: CGRect, containerSize: CGSize) -> CGRect {
        // 仅用于显示：对照模式下，把选区显示区域向下扩展一些，方便同时看原文+译文。
        // 注意：不修改 session.selectionRect，避免影响实际截图区域。
        let isCompare = session.showCompare && session.stage == .translated
        guard isCompare else { return baseRectTopLeft }

        let margin: CGFloat = 12
        let desiredMinHeight: CGFloat = 320

        let availableHeight = max(0, containerSize.height - baseRectTopLeft.minY - margin)
        let newHeight = min(max(baseRectTopLeft.height, desiredMinHeight), availableHeight)
        return CGRect(x: baseRectTopLeft.minX, y: baseRectTopLeft.minY, width: baseRectTopLeft.width, height: newHeight)
    }

    private func hudToastPosition(containerSize: CGSize, selectionRectTopLeft: CGRect) -> CGPoint {
        let toolbarSize = CGSize(width: 420, height: 118)
        let toastSize = CGSize(width: 360, height: 44)
        let margin: CGFloat = 10

        let toolbarCenter = toolbarPosition(containerSize: containerSize, selectionRectTopLeft: selectionRectTopLeft)
        let x = clamp(toolbarCenter.x, min: toastSize.width / 2 + 12, max: containerSize.width - toastSize.width / 2 - 12)
        let y = clamp(toolbarCenter.y + toolbarSize.height / 2 + margin + toastSize.height / 2, min: toastSize.height / 2 + 12, max: containerSize.height - toastSize.height / 2 - 12)
        return CGPoint(x: x, y: y)
    }

    private func normalizedRectTopLeft(start: CGPoint, current: CGPoint) -> CGRect {
        let x1 = min(start.x, current.x)
        let x2 = max(start.x, current.x)
        let y1 = min(start.y, current.y)
        let y2 = max(start.y, current.y)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    // SwiftUI(左上原点) -> AppKit 内容坐标(左下原点)
    private func rectToBottomLeft(rectTopLeft: CGRect, containerSize: CGSize) -> CGRect {
        CGRect(
            x: rectTopLeft.minX,
            y: containerSize.height - rectTopLeft.maxY,
            width: rectTopLeft.width,
            height: rectTopLeft.height
        )
    }

    // AppKit 内容坐标(左下原点) -> SwiftUI(左上原点)
    private func rectToTopLeft(rectBottomLeft: CGRect, containerSize: CGSize) -> CGRect {
        CGRect(
            x: rectBottomLeft.minX,
            y: containerSize.height - rectBottomLeft.maxY,
            width: rectBottomLeft.width,
            height: rectBottomLeft.height
        )
    }

    private func hudToastView(_ toast: ScreenshotOCRSession.HUDToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hudIcon(for: toast.style))
                .font(.system(size: 14, weight: .semibold))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hudBackground(for: toast.style))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: toast.id)
    }

    private func hudIcon(for style: ScreenshotOCRSession.HUDToast.Style) -> String {
        switch style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func hudBackground(for style: ScreenshotOCRSession.HUDToast.Style) -> Color {
        switch style {
        case .success: return Color.green.opacity(0.92)
        case .info: return Color.blue.opacity(0.92)
        case .warning: return Color.orange.opacity(0.92)
        case .error: return Color.red.opacity(0.92)
        }
    }
}
