import SwiftUI

struct InfoTip: View {
    let text: String
    @State private var isPresented: Bool = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.system(size: 12))
                .padding(12)
                .frame(width: 280, alignment: .leading)
        }
        .accessibilityLabel("提示")
    }
}
