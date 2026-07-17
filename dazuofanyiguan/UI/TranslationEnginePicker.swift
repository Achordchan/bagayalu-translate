import SwiftUI

struct TranslationEnginePicker: View {
    @Binding var selection: String
    let statusColor: Color

    @Environment(\.colorScheme) private var scheme
    @State private var isPresented = false
    @State private var isHovering = false
    @State private var hoveringEngine: TranslationEngineType?

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 10) {
                Text("服务")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .fixedSize()

                Text(selectedEngine.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
            .homeToolbarPickerChrome(isHovering: $isHovering)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 4) {
                ForEach(TranslationEngineType.allCases) { engine in
                    Button {
                        selection = engine.rawValue
                        isPresented = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: engine.systemImageName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)

                            Text(engine.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)

                            Spacer()

                            if engine == selectedEngine {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveringEngine = hovering ? engine : nil
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(rowBackgroundColor(for: engine))
                    )
                }
            }
            .padding(8)
            .frame(width: 238)
        }
        .accessibilityIdentifier("home.translationServiceMenu")
        .accessibilityLabel("翻译服务")
        .accessibilityValue(selectedEngine.title)
        .accessibilityHint("打开列表以切换翻译服务")
        .help("当前翻译服务：\(selectedEngine.title)")
    }

    private var selectedEngine: TranslationEngineType {
        TranslationEngineType(rawValue: selection) ?? .apple
    }

    private func rowBackgroundColor(for engine: TranslationEngineType) -> Color {
        if engine == selectedEngine {
            return Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14)
        }
        if engine == hoveringEngine {
            return DS.cardBackground(scheme).opacity(1.35)
        }
        return Color.clear
    }
}
