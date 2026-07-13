import AppKit
import SwiftUI

struct HelpAboutSettingsPane: View {
    let appVersion: String
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void

    @State private var expandedFAQ: Set<Int> = [0]

    var body: some View {
        VStack(spacing: 20) {
            SettingsGroup(title: "常见问题") {
                faqItem(
                    index: 0,
                    question: "不授权辅助功能还能使用吗？",
                    answer: "可以。选择剪贴板监听模式后，双击 Command + C 会读取剪贴板并翻译；无法复制的内容则无法触发。"
                )
                Divider()
                faqItem(
                    index: 1,
                    question: "为什么双击 Command + C 没反应？",
                    answer: "检查快捷翻译是否启用、触发方式是否正确，以及两次按键是否超过设置的时间窗口。全局快捷键模式还需要辅助功能权限。"
                )
                Divider()
                faqItem(
                    index: 2,
                    question: "截图翻译识别不准怎么办？",
                    answer: "尽量选择清晰、对比度高的文字区域。能直接复制文字时，文字快捷翻译通常更准确。"
                )
                Divider()
                faqItem(
                    index: 3,
                    question: "为什么需要屏幕录制权限？",
                    answer: "截图翻译需要读取选区像素并执行 OCR；关闭屏幕录制权限后，截图功能无法获取画面。"
                )
            }

            SettingsGroup(title: "关于应用") {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("大佐翻译官")
                            .font(.system(size: 16, weight: .semibold))
                        Text("版本 \(appVersion)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("作者 Achord")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("检查更新") {
                        onCheckForUpdates()
                    }
                    .disabled(!canCheckForUpdates)
                }

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("应用内自动更新")
                            .font(.system(size: 12, weight: .medium))
                        Text("每天自动检查；安装完成后自动重启到最新版本")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Divider()

                aboutRow(
                    icon: "envelope",
                    title: "联系邮箱",
                    value: "achordchan@gmail.com",
                    destination: "mailto:achordchan@gmail.com"
                )

                aboutRow(
                    icon: "phone",
                    title: "联系电话",
                    value: "13160235855",
                    destination: "tel:13160235855"
                )
            }

            SettingsGroup(title: "项目与条款") {
                resourceLink(
                    icon: "chevron.left.slash.chevron.right",
                    title: "项目地址",
                    subtitle: "查看源代码、版本记录和问题反馈",
                    url: "https://github.com/Achordchan/bagayalu-translate"
                )
                Divider()
                resourceLink(
                    icon: "hand.raised",
                    title: "隐私条款",
                    subtitle: "了解数据处理和权限用途",
                    url: "https://github.com/Achordchan/bagayalu-translate/blob/main/PRIVACY.md"
                )
                Divider()
                resourceLink(
                    icon: "doc.text",
                    title: "开源协议",
                    subtitle: "查看项目许可证",
                    url: "https://github.com/Achordchan/bagayalu-translate/blob/main/LICENSE"
                )
                Divider()
                resourceLink(
                    icon: "heart",
                    title: "赞助项目",
                    subtitle: "支持应用继续维护",
                    url: "https://ifdian.net/a/achord"
                )
            }
        }
    }

    private func faqItem(
        index: Int,
        question: String,
        answer: String
    ) -> some View {
        let isExpanded = expandedFAQ.contains(index)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded {
                    expandedFAQ.remove(index)
                } else {
                    expandedFAQ.insert(index)
                }
            } label: {
                HStack(spacing: 10) {
                    Text(question)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(answer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 24)
            }
        }
    }

    private func aboutRow(
        icon: String,
        title: String,
        value: String,
        destination: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            if let url = URL(string: destination) {
                Link(value, destination: url)
                    .font(.system(size: 12))
            }
        }
    }

    private func resourceLink(
        icon: String,
        title: String,
        subtitle: String,
        url: String
    ) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
