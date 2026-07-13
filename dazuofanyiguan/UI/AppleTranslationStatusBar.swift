import SwiftUI

struct AppleTranslationStatusBar: View {
    let phaseText: String?
    let isWaitingForLanguageDownload: Bool

    @State private var downloadStartedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Image(systemName: "apple.logo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if isWaitingForLanguageDownload {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统正在下载语言模型")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(downloadEstimateText(at: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text("已等待 \(elapsedText(at: context.date))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(phaseText ?? "正在使用 Apple 本地翻译")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(
            Divider(),
            alignment: .top
        )
        .onChange(of: isWaitingForLanguageDownload) { _, isWaiting in
            if isWaiting {
                downloadStartedAt = Date()
            }
        }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsedSeconds = elapsedSeconds(at: date)
        let hours = elapsedSeconds / 3_600
        let minutes = (elapsedSeconds % 3_600) / 60
        let seconds = elapsedSeconds % 60

        if hours > 0 {
            return "\(hours)小时\(minutes)分\(seconds)秒"
        }
        if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        }
        return "\(seconds)秒"
    }

    private func downloadEstimateText(at date: Date) -> String {
        if elapsedSeconds(at: date) < 5 * 60 {
            return "预计总耗时约 1–5 分钟，实际进度以系统设置为准"
        }
        return "下载时间受网络和系统状态影响，实际进度以系统设置为准"
    }

    private func elapsedSeconds(at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(downloadStartedAt)))
    }
}
