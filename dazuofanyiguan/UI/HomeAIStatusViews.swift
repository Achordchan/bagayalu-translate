import SwiftUI

struct AICompletedInfoButton: View {
    let model: String
    let durationMs: Int?
    let estimatedTokens: Int?

    @State private var showInfo: Bool = false

    var body: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("AI 请求已完成")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("模型")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(model)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("运行时间")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let durationMs {
                        Text("\(durationMs) ms")
                            .font(.system(size: 12))
                    } else {
                        Text("未知")
                            .font(.system(size: 12))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("预计消耗")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let estimatedTokens {
                        Text("Token 数：\(estimatedTokens)")
                            .font(.system(size: 12))
                    } else {
                        Text("Token 数：未知")
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }
}


struct AITranslatingStatusBar: View {
    let model: String
    let estimatedTokens: Int?
    let phaseText: String?

    @State private var showInfo: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 4
            let dots = String(repeating: "。", count: step)
            HStack(spacing: 8) {
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.secondary)
                            Text("AI 翻译详情")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("当前状态")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(phaseText ?? "正在等待服务端响应")
                                .font(.system(size: 12))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("预计消耗")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            if let estimatedTokens {
                                Text("Token 数：\(estimatedTokens)")
                                    .font(.system(size: 12))
                            } else {
                                Text("Token 数：未知")
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .padding(14)
                    .frame(width: 260)
                }

                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("正在调用AI模型-\(model)翻译，请稍候\(dots)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(
                Divider(),
                alignment: .top
            )
        }
    }
}
