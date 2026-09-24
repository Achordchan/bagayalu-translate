import AppKit
import SwiftUI

struct PermissionGuideView: View {
    let needsAccessibility: Bool
    let needsScreenRecording: Bool
    let showsScreenRecordingPermission: Bool

    let onOpenAccessibility: () -> Void
    let onOpenScreenRecording: () -> Void
    let onClose: () -> Void

    @State private var showFallbackExplanation = false
    @State private var showPermissionMigrationExplanation = false

    private var requiredPermissionCount: Int {
        showsScreenRecordingPermission ? 2 : 1
    }

    private var grantedPermissionCount: Int {
        requiredPermissionCount
            - [needsAccessibility, showsScreenRecordingPermission && needsScreenRecording]
                .filter { $0 }
                .count
    }

    private var allPermissionsGranted: Bool {
        !needsAccessibility
            && (!showsScreenRecordingPermission || !needsScreenRecording)
    }

    var body: some View {
        VStack(spacing: 0) {
            guideHeader

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    permissionOverview

                    permissionRow(
                        icon: "accessibility",
                        title: "辅助功能",
                        capability: showsScreenRecordingPermission
                            ? "全局文字快捷键与截图快捷键"
                            : "全局文字快捷键",
                        detail: "允许应用在其他软件中响应 Command + C + C 等全局快捷键。",
                        isGranted: !needsAccessibility,
                        actionTitle: "打开辅助功能设置",
                        action: onOpenAccessibility
                    )

                    if showsScreenRecordingPermission {
                        permissionRow(
                            icon: "rectangle.dashed.badge.record",
                            title: "屏幕录制",
                            capability: "截图翻译与 OCR 取字",
                            detail: "允许应用读取你主动框选的屏幕区域，用于文字识别和翻译。",
                            isGranted: !needsScreenRecording,
                            actionTitle: "打开屏幕录制设置",
                            action: onOpenScreenRecording
                        )
                    }

                    fallbackExplanation
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("权限状态会在你返回应用后自动刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                if allPermissionsGranted {
                    Button("完成", action: onClose)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("稍后处理", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var guideHeader: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(allPermissionsGranted ? "权限已准备完成" : "完善权限以启用全部功能")
                    .font(.system(size: 20, weight: .semibold))

                Text(
                    allPermissionsGranted
                        ? completedPermissionDescription
                        : "仅在使用对应功能时需要这些系统权限。"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var permissionOverview: some View {
        HStack(spacing: 12) {
            Image(
                systemName: allPermissionsGranted
                    ? "checkmark.shield.fill"
                    : "shield.lefthalf.filled"
            )
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(allPermissionsGranted ? Color.green : Color.orange)
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text("已完成 \(grantedPermissionCount) / \(requiredPermissionCount)")
                    .font(.system(size: 13, weight: .semibold))
                Text("应用只会在你主动使用对应功能时读取所需内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    (allPermissionsGranted ? Color.green : Color.orange)
                        .opacity(0.08)
                )
        )
    }

    private var completedPermissionDescription: String {
        showsScreenRecordingPermission
            ? "全局快捷翻译和截图翻译均可正常使用。"
            : "全局快捷翻译已可正常使用。"
    }

    private var fallbackExplanation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showFallbackExplanation.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showFallbackExplanation ? 90 : 0))

                    Text("暂不授权辅助功能还能使用吗？")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFallbackExplanation {
                Text("可以。在设置中选择“剪贴板监听”后，连续按两次 Command + C 会读取剪贴板并翻译。无法复制的网页或控件不会产生可翻译内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.leading, 19)
            }

            Divider()
                .padding(.vertical, 12)

            Button {
                showPermissionMigrationExplanation.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(
                            .degrees(showPermissionMigrationExplanation ? 90 : 0)
                        )

                    Text("系统设置已开启，为什么仍提示未授权？")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showPermissionMigrationExplanation {
                Text("1.2.1 及更早版本使用临时签名，首次升级到正式签名版本时，macOS 可能仍保留无法匹配的旧权限记录。请在系统设置中删除旧条目，再把上方应用图标拖入权限列表并开启；完成这一次迁移后，后续更新会保持同一权限身份。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.leading, 19)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
    }

    private func permissionRow(
        icon: String,
        title: String,
        capability: String,
        detail: String,
        isGranted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))

                    Label(
                        isGranted ? "已授权" : "未授权",
                        systemImage: isGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                }

                Text(capability)
                    .font(.system(size: 12, weight: .medium))

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isGranted {
                    permissionDragGuide(
                        actionTitle: actionTitle,
                        action: action
                    )
                    .padding(.top, 7)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func permissionDragGuide(
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            draggableApplicationIcon

            VStack(alignment: .leading, spacing: 3) {
                Text("拖入权限列表")
                    .font(.system(size: 11, weight: .semibold))
                Text("先打开对应系统设置，再把左侧图标拖入应用列表并开启开关。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var draggableApplicationIcon: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)

                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Color.orange))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
            }

            Text("拖动")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 54)
        // `.help` 留给 VoiceOver；盖在上面的拖拽源会挡住鼠标悬停，悬停提示由它自己的 toolTip 出。
        .help(Self.dragHelp)
        .overlay {
            PermissionGuideApplicationDragSource(
                applicationURL: Bundle.main.bundleURL,
                toolTip: Self.dragHelp
            )
        }
    }

    private static let dragHelp = "将大佐翻译官拖到系统设置的权限列表"
}

/// 权限引导里「拖到系统设置」的拖拽源：拖拽剪贴板里只放 .app 的文件引用。
///
/// 不用 SwiftUI 的 `.onDrag { NSItemProvider(object: url as NSURL) }`：实测别的进程一读拖拽里的
/// `public.file-url`（系统设置在松手时读，有的接收方悬停时就读），SwiftUI 就把整个 .app 拷进
/// `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/`，交出去的是拷贝的路径，拷贝从不清理。
/// 这份拷贝随后以同一 bundle ID 登记进 LaunchServices，「退出并重新打开」就可能挑中它。
struct PermissionGuideApplicationDragSource: NSViewRepresentable {
    let applicationURL: URL
    let toolTip: String

    func makeNSView(context: Context) -> DragSourceView {
        DragSourceView(applicationURL: applicationURL)
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.applicationURL = applicationURL
        nsView.toolTip = toolTip
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var applicationURL: URL
        private var mouseDownEvent: NSEvent?

        init(applicationURL: URL) {
            self.applicationURL = applicationURL
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // 用户通常先打开系统设置、再从后面的引导窗口拖：第一下按住就能拖，
        // 拖动时引导窗口也不跳到系统设置前面挡住列表。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent else { return }
            self.mouseDownEvent = nil

            NSApp.preventWindowOrdering()
            let location = convert(mouseDownEvent.locationInWindow, from: nil)
            beginDraggingSession(
                with: [
                    PermissionGuideApplicationDrag.draggingItem(
                        applicationURL: applicationURL,
                        centeredAt: location,
                        image: NSApp.applicationIconImage
                    )
                ],
                event: mouseDownEvent,
                source: self
            )
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            PermissionGuideApplicationDrag.operationMask(for: context)
        }

        // 按住 ⌘ / ⌃ 时 AppKit 会把可选操作收窄成 generic / link，和只给的 copy 一交就空了，拖不进去。
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            true
        }
    }
}

enum PermissionGuideApplicationDrag {
    static let iconSize: CGFloat = 42

    /// `NSURL` 作为 `NSPasteboardWriting` 只写文件引用（`public.file-url` 及其旧式别名），
    /// 不经过 `NSItemProvider`，也就没有 SwiftUI 替接收方「备一份文件」的那一步。
    static func draggingItem(
        applicationURL: URL,
        centeredAt location: NSPoint,
        image: NSImage
    ) -> NSDraggingItem {
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(
            NSRect(
                x: location.x - iconSize / 2,
                y: location.y - iconSize / 2,
                width: iconSize,
                height: iconSize
            ),
            contents: image
        )
        return item
    }

    /// 只给 copy：旧版 SwiftUI 拖拽给的也只有 copy，系统设置照收。
    /// 不给 move / delete，免得拖进废纸篓或 Finder 时把正式安装的 .app 挪走；本应用里没有接收方。
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return .copy
        case .withinApplication:
            return []
        @unknown default:
            return []
        }
    }
}
