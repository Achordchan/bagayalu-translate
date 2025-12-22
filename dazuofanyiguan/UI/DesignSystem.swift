import SwiftUI

enum DS {
    static let cornerRadius: CGFloat = 12
    static let pillCornerRadius: CGFloat = 12

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.06)
        default:
            return Color.black.opacity(0.06)
        }
    }

    static func strokeColor(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.white.opacity(0.08)
        default:
            return Color.black.opacity(0.06)
        }
    }
}

struct Card: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .fill(DS.cardBackground(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .strokeBorder(DS.strokeColor(scheme), lineWidth: 1)
            )
    }
}

struct Pill: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.pillCornerRadius, style: .continuous)
                    .fill(DS.cardBackground(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.pillCornerRadius, style: .continuous)
                    .strokeBorder(DS.strokeColor(scheme), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.pillCornerRadius, style: .continuous))
    }
}

struct IconPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 34, height: 32)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

extension View {
    func dsCard() -> some View { modifier(Card()) }
    func dsPill() -> some View { modifier(Pill()) }
}
