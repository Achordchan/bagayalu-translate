import Foundation
import SwiftUI

@MainActor
final class ToastCenter: ObservableObject {
    struct Toast: Identifiable {
        enum Style {
            case success
            case info
            case warning
            case error
        }

        let id = UUID()
        let style: Style
        let message: String
    }

    @Published private(set) var toast: Toast?

    func show(_ message: String, style: Toast.Style = .info, duration: TimeInterval = 2.0) {
        toast = .init(style: style, message: message)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self.toast?.message == message {
                self.toast = nil
            }
        }
    }

    func clear() {
        toast = nil
    }
}
