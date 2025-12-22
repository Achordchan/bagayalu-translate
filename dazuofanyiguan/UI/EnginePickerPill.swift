import SwiftUI

struct EnginePickerPill: View {
    @Binding var selectionRawValue: String
    let statusColor: Color
    @State private var isPresented: Bool = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engine == .google ? "g.circle.fill" : "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(engine == .google ? .blue : .purple)

                Text("翻译服务")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(engine.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(0.9)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .dsPill()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择翻译服务")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                Divider()

                ForEach(TranslationEngineType.allCases) { item in
                    Button {
                        selectionRawValue = item.rawValue
                        isPresented = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item == .google ? "g.circle.fill" : "sparkles")
                                .foregroundStyle(item == .google ? .blue : .purple)
                                .frame(width: 18)
                            Text(item.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if item.rawValue == selectionRawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .frame(width: 320, height: 180)
        }
    }

    private var engine: TranslationEngineType {
        TranslationEngineType(rawValue: selectionRawValue) ?? .google
    }
}
