import AppKit
import SwiftUI

/// 控制台里用到的日志级别。`LogStore` 存的是字符串，这里只负责把它们映射成显示用的名字和颜色。
enum LogConsoleLevel: String, CaseIterable, Identifiable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    var id: String { rawValue }

    init?(level: String) {
        self.init(rawValue: level.uppercased())
    }

    var title: String {
        switch self {
        case .info: return "信息"
        case .warn: return "警告"
        case .error: return "错误"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .accentColor
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// 控制台的筛选、计数和复制文本。纯函数，不碰界面，方便单测。
enum LogConsoleFilter {
    /// `level == nil` 表示全部级别；关键字不分大小写，只匹配消息正文，首尾空白忽略。
    /// 结果按时间倒序（最新的在最上面）。
    static func visibleEntries(
        _ entries: [LogStore.Entry],
        level: LogConsoleLevel?,
        query: String
    ) -> [LogStore.Entry] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.reversed().filter { entry in
            if let level, LogConsoleLevel(level: entry.level) != level {
                return false
            }
            if !keyword.isEmpty,
               entry.message.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
            return true
        }
    }

    static func count(_ entries: [LogStore.Entry], level: LogConsoleLevel) -> Int {
        entries.reduce(into: 0) { total, entry in
            if LogConsoleLevel(level: entry.level) == level { total += 1 }
        }
    }

    /// 复制出去的文本按时间正序排，和贴进聊天、工单时人读的顺序一致。
    static func clipboardText(_ visibleNewestFirst: [LogStore.Entry]) -> String {
        visibleNewestFirst.reversed()
            .map { "\(timeText($0.date)) [\($0.level)] \($0.message)" }
            .joined(separator: "\n")
    }

    static func timeText(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // 以前每行渲染都新建一个 DateFormatter，500 条就是 500 次。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct LogConsoleView: View {
    @EnvironmentObject private var log: LogStore

    @StateObject private var windowBehavior = ConsoleWindowBehavior()
    @State private var levelFilter: LogConsoleLevel?
    @State private var query = ""
    @State private var didCopy = false

    var body: some View {
        let visible = LogConsoleFilter.visibleEntries(log.entries, level: levelFilter, query: query)

        HomeTranslationPanel(
            icon: "terminal",
            title: "控制台",
            subtitle: subtitle(visibleCount: visible.count)
        ) {
            HStack(spacing: 6) {
                Button {
                    copy(visible)
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(HomePanelActionButtonStyle())
                .disabled(visible.isEmpty)
                .opacity(visible.isEmpty ? 0.4 : 1)
                .help("复制当前显示的日志")

                Button {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(HomePanelActionButtonStyle())
                .disabled(log.entries.isEmpty)
                .opacity(log.entries.isEmpty ? 0.4 : 1)
                .help("清空日志")
            }
        } content: {
            VStack(spacing: 0) {
                filterBar
                Divider()
                list(visible)
            }
        }
        .padding(14)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 380, idealHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(
            WindowAccessor { window in
                windowBehavior.attach(window)
            }
            .frame(width: 0, height: 0)
        )
    }

    private var isFiltering: Bool {
        levelFilter != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func subtitle(visibleCount: Int) -> String {
        let total = log.entries.count
        if total == 0 { return "仅保留本次运行的最近 500 条" }
        return isFiltering ? "显示 \(visibleCount) / \(total) 条" : "共 \(total) 条 · 仅保留本次运行的最近 500 条"
    }

    // MARK: - 筛选栏

    private var filterBar: some View {
        HStack(spacing: 6) {
            LogLevelChip(
                title: "全部",
                count: log.entries.count,
                tint: .accentColor,
                highlightsCount: false,
                isSelected: levelFilter == nil
            ) {
                levelFilter = nil
            }

            ForEach(LogConsoleLevel.allCases) { level in
                LogLevelChip(
                    title: level.title,
                    count: LogConsoleFilter.count(log.entries, level: level),
                    tint: level.tint,
                    highlightsCount: level != .info,
                    isSelected: levelFilter == level
                ) {
                    levelFilter = levelFilter == level ? nil : level
                }
            }

            Spacer(minLength: 12)

            LogSearchField(text: $query)
                .frame(width: 220)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    // MARK: - 列表

    @ViewBuilder
    private func list(_ visible: [LogStore.Entry]) -> some View {
        if visible.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { entry in
                        LogConsoleRow(entry: entry)
                    }
                }
                .padding(8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: log.entries.isEmpty ? "text.alignleft" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)

            Text(log.entries.isEmpty ? "暂无日志" : "没有符合条件的日志")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(
                log.entries.isEmpty
                    ? "翻译、截图翻译和选区翻译的运行记录会显示在这里"
                    : "调整关键字或级别筛选后再试"
            )
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ visible: [LogStore.Entry]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(LogConsoleFilter.clipboardText(visible), forType: .string)

        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    @MainActor
    private final class ConsoleWindowBehavior: NSObject, ObservableObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private var didCenterThisShow: Bool = false

        func attach(_ window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                self.window = window
                window.isRestorable = false
                window.delegate = self
                didCenterThisShow = false
            }
        }

        func windowDidBecomeKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if !didCenterThisShow {
                didCenterThisShow = true
                window.center()
            }
        }

        func windowDidResignKey(_ notification: Notification) {
            // 点击窗口外关闭。
            (notification.object as? NSWindow)?.performClose(nil)
        }

        func windowWillClose(_ notification: Notification) {
            didCenterThisShow = false
        }
    }
}

// MARK: - 子视图

private struct LogConsoleRow: View {
    let entry: LogStore.Entry

    @State private var isHovering = false

    private var level: LogConsoleLevel? { LogConsoleLevel(level: entry.level) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LogConsoleFilter.timeText(entry.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            Text(level?.title ?? entry.level)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(level?.tint ?? .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill((level?.tint ?? .secondary).opacity(0.12))
                )

            Text(entry.message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        switch level {
        case .error: return Color.red.opacity(isHovering ? 0.10 : 0.06)
        case .warn: return Color.orange.opacity(isHovering ? 0.09 : 0.05)
        default: return Color.primary.opacity(isHovering ? 0.05 : 0)
        }
    }
}

private struct LogLevelChip: View {
    let title: String
    let count: Int
    let tint: Color
    /// 警告、错误有数量时数字带颜色：不点开也能一眼看出有没有出错。
    let highlightsCount: Bool
    let isSelected: Bool
    let action: () -> Void

    private var countColor: Color {
        isSelected || (highlightsCount && count > 0) ? tint : .secondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(countColor)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.32) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct LogSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)

            TextField("搜索日志", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}
