import SwiftUI

/// 输入增强测试页（PRD §48）。
///
/// 用户开完权限、配好语言之后，应该能立刻在这里验证一遍，
/// 而不是先跑去微信里试、试不出来又不知道是哪一环出了问题。
struct InputAssistTestView: View {
    @ObservedObject var settings: InputAssistSettings
    @ObservedObject var coordinator: InputAssistCoordinator

    @State private var draft = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusRow
            editor
            hints
            Spacer(minLength: 0)
            metricsRow
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { isEditorFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("输入增强测试")
                .font(.system(size: 18, weight: .semibold))
            Text("在下面的框里用中文输入法打一句话，确认上屏后按 \(settings.shortcut.displayString)。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 18) {
            statusItem("辅助功能", isOK: coordinator.isAccessibilityTrusted)
            statusItem("快捷键", isOK: coordinator.hotkeyStatus.isActive)
            statusItem("已启用", isOK: settings.isEnabled)
            statusItem(
                "目标语言 \(settings.targetLanguageCodes.count)",
                isOK: !settings.targetLanguageCodes.isEmpty
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func statusItem(_ title: String, isOK: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isOK ? Color.green : Color.orange)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 11))
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 15))
            .focused($isEditorFocused)
            .frame(minHeight: 150)
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.3))
            )
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 5) {
            hint("↑ / ↓", "在候选之间移动")
            hint("Enter", "用当前高亮译文替换原文")
            hint("⌘1–⌘6", "直接选中对应语言并替换")
            hint("⌘C", "只复制译文，不替换")
            hint("⌥ 按住", "临时显示引擎、耗时和缓存状态")
            hint("Esc", "关闭候选浮层")
            hint("⌘Z", "替换之后可以撤销回原文")
        }
    }

    private func hint(_ key: String, _ description: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .frame(width: 74, alignment: .leading)
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var metricsRow: some View {
        let metrics = coordinator.metrics
        return Text(
            "触发 \(metrics.manualTriggerCount) · 展示 \(metrics.candidateShowCount) · "
                + "替换 \(metrics.candidateCommitCount) · 缓存命中 \(metrics.cacheHitCount) · "
                + "安全放弃 \(metrics.safeAbortCount)"
        )
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
}
