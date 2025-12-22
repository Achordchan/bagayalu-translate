import SwiftUI

struct LanguageSearchPicker: View {
    let title: String
    let allowAuto: Bool
    let options: [Language]
    @Binding var selection: String
    var fixedWidth: CGFloat?

    @Environment(\.colorScheme) private var scheme

    @State private var isPresented: Bool = false
    @State private var query: String = ""
    @State private var isHovering: Bool = false
    @State private var hoveringCode: String?

    var body: some View {
        Button {
            query = ""
            isPresented = true
        } label: {
            Group {
                if fixedWidth != nil {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(selectedName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(selectedName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.pillCornerRadius, style: .continuous)
                    .fill(
                        isHovering
                        ? DS.cardBackground(scheme).opacity(1.25)
                        : DS.cardBackground(scheme)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.pillCornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                DS.strokeColor(scheme).opacity(1.0),
                                Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.pillCornerRadius, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .buttonStyle(.plain)
        .frame(width: fixedWidth, alignment: .leading)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                TextField("搜索语言", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                List(filteredOptions, id: \.code) { item in
                    Button {
                        selection = item.code
                        isPresented = false
                    } label: {
                        HStack {
                            Text(item.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            if item.code == selection {
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
                        hoveringCode = hovering ? item.code : nil
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(rowBackgroundColor(code: item.code))
                    )
                }
                .listStyle(.plain)
            }
            .frame(width: 200, height: 400)
        }
    }

    private func rowBackgroundColor(code: String) -> Color {
        if code == selection {
            return Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14)
        }
        if hoveringCode == code {
            return DS.cardBackground(scheme).opacity(1.35)
        }
        return Color.clear
    }

    private var selectedName: String {
        options.first(where: { $0.code == selection })?.name ?? selection
    }

    private var filteredOptions: [Language] {
        let list = allowAuto ? options : options.filter { $0.code != LanguagePreset.auto.code }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q) }
    }
}
