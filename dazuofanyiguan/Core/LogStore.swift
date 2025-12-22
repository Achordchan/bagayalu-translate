import Foundation

@MainActor
final class LogStore: ObservableObject {
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
        print("[\(level)] \(message)")
    }
}
