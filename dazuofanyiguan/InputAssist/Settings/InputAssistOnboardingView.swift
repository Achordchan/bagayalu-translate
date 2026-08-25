import SwiftUI

/// 新功能推荐（PRD §6.2）。
///
/// **只出现一次。** 用户点了「以后再说」就不再自动弹，
/// 入口永久保留在设置页和菜单栏（PRD §6.2 规则）。
struct InputAssistOnboardingView: View {
    @ObservedObject var settings: InputAssistSettings
    @ObservedObject var coordinator: InputAssistCoordinator

    let onOpenPermissionGuide: () -> Void
    let onOpenTestWindow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("新功能：选区翻译")
                    .font(.system(size: 19, weight: .semibold))
                Text("在任意应用里选中文字，按快捷键查看多语言翻译候选。支持精确写入的编辑器可原位替换，其它应用会复制译文。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            demo

            VStack(alignment: .leading, spacing: 5) {
                bullet("只处理你明确选中的文字")
                bullet("无法安全替换时只复制，不模拟粘贴")
                bullet("密码框和安全输入状态永远跳过")
            }

            HStack {
                Button("以后再说") {
                    settings.didOfferOnboarding = true
                    onDismiss()
                }
                Spacer()
                Button("开启选区翻译") {
                    settings.didOfferOnboarding = true
                    settings.isEnabled = true
                    coordinator.applyEnabledState()
                    if coordinator.isAccessibilityTrusted {
                        onOpenTestWindow()
                    } else {
                        onOpenPermissionGuide()
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var demo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我们可以提供16吨船吊")
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 3) {
                demoRow("EN", "We can provide a 16-ton marine crane.", isSelected: true)
                demoRow("ES", "Podemos suministrar una grúa marina de 16 t.", isSelected: false)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func demoRow(_ code: String, _ text: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(code)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(width: 24, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 把推荐挂到主窗口上。只在从未推荐过、且功能还没被打开时出现一次。
private struct InputAssistOnboardingPresenter: ViewModifier {
    @ObservedObject var settings: InputAssistSettings
    @ObservedObject var coordinator: InputAssistCoordinator

    @Environment(\.openWindow) private var openWindow
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !settings.didOfferOnboarding, !settings.isEnabled else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                InputAssistOnboardingView(
                    settings: settings,
                    coordinator: coordinator,
                    onOpenPermissionGuide: {
                        NotificationCenter.default.post(
                            name: .dazuofanyiguanOpenPermissionGuide,
                            object: nil
                        )
                    },
                    onOpenTestWindow: { openWindow(id: "inputAssistTest") },
                    onDismiss: { isPresented = false }
                )
            }
    }
}

extension View {
    func inputAssistOnboarding(
        settings: InputAssistSettings,
        coordinator: InputAssistCoordinator
    ) -> some View {
        modifier(InputAssistOnboardingPresenter(settings: settings, coordinator: coordinator))
    }
}
