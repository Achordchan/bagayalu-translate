import Foundation
import SwiftUI

@MainActor
final class LogStore: ObservableObject {
    nonisolated init() {}

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    func info(_ message: String) {
        append(level: "INFO", message: message)
    }

    func warn(_ message: String) {
        append(level: "WARN", message: message)
    }

    func error(_ message: String) {
        append(level: "ERROR", message: message)
    }

    func clear() {
        entries.removeAll()
    }

    private func append(level: String, message: String) {
        entries.append(.init(date: Date(), level: level, message: message))
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
        #if DEBUG
        print("[\(level)] \(message)")
        #endif
    }
}

private struct LogStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue = LogStore()
}

extension EnvironmentValues {
    /// 不参与变更订阅的 LogStore 入口。
    ///
    /// 只需要往下传日志、不读 `entries` 的视图应该用它而不是 `@EnvironmentObject`：
    /// `@EnvironmentObject` 会订阅整个对象，于是每写一条日志都会让那些视图重新求值。
    var logStore: LogStore {
        get { self[LogStoreEnvironmentKey.self] }
        set { self[LogStoreEnvironmentKey.self] = newValue }
    }
}
