import SwiftUI

struct HomeTranslationPanel<Actions: View, Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct HomePanelActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct TranslationOutputEmptyState: View {
    let isTranslating: Bool

    var body: some View {
        VStack(spacing: 9) {
            if isTranslating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "character.bubble")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Text(isTranslating ? "正在翻译" : "等待翻译")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            if !isTranslating {
                Text("在左侧输入文字，结果会显示在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
