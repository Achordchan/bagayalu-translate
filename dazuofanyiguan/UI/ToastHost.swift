import SwiftUI

struct ToastHost: ViewModifier {
    @EnvironmentObject private var toastCenter: ToastCenter

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            if let toast = toastCenter.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.9), value: toast.id)
            }
        }
    }
}

private struct ToastView: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
    }

    private var icon: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var background: Color {
        switch toast.style {
        case .success: return Color.green.opacity(0.92)
        case .info: return Color.blue.opacity(0.92)
        case .warning: return Color.orange.opacity(0.92)
        case .error: return Color.red.opacity(0.92)
        }
    }
}

extension View {
    func toastHost() -> some View {
        modifier(ToastHost())
    }
}
