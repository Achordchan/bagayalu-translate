import SwiftUI

struct TranslationTimeoutBanner: View {
    let onCancel: () -> Void

    let waitedSeconds: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("翻译耗时较长")
                    .font(.system(size: 13, weight: .semibold))
                Text("这段内容较长，翻译可能需要更久。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text("当前已等待\(waitedSeconds)秒")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Button("取消翻译") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
        .frame(maxWidth: 720)
        .padding(.horizontal, 12)
    }
}
