import AppKit
import SwiftUI

struct LogConsoleView: View {
    @EnvironmentObject private var log: LogStore

    @StateObject private var windowBehavior = ConsoleWindowBehavior()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("控制台")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("清空") {
                    log.clear()
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(log.entries.reversed())) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Text(formatDate(item.date))
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(item.level)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(color(for: item.level))
                                .frame(width: 52, alignment: .leading)
                            Text(item.message)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 720, height: 420)
        .background(
            WindowAccessor { window in
                windowBehavior.attach(window)
            }
            .frame(width: 0, height: 0)
        )
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

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func color(for level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        default: return .blue
        }
    }
}
