import SwiftUI

/// 输入增强设置页（PRD §47）。
///
/// 这一版只放已经实现的能力。自动触发相关的开关等 Phase 3 真正做完再出现——
/// 摆一个点了没反应的开关比没有这个开关更糟。
struct InputAssistSettingsPane: View {
    @ObservedObject var settings: InputAssistSettings
    @ObservedObject var coordinator: InputAssistCoordinator

    let hasAccessibilityPermission: Bool
    let engineTitle: String
    let onOpenPermissionGuide: () -> Void
    let onOpenTestWindow: () -> Void

    @State private var cacheUsageText = "统计中…"
    @State private var isAddingLanguage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            enableSection
            if settings.isEnabled {
                triggerSection
                targetLanguageSection
                engineSection
                scopeSection
                cacheSection
                debugSection
            }
        }
        .task(id: settings.isEnabled) {
            await refreshCacheUsage()
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用输入增强", isOn: Binding(
                get: { settings.isEnabled },
                set: { newValue in
                    settings.isEnabled = newValue
                    coordinator.applyEnabledState()
                }
            ))
            .font(.system(size: 13, weight: .medium))

            Text("用你习惯的中文输入法照常打字，确认上屏后按快捷键，就能用译文直接替换刚输入的内容。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if settings.isEnabled, !hasAccessibilityPermission {
                permissionBanner
            }

            if let message = coordinator.lastStatusMessage, hasAccessibilityPermission {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要辅助功能权限")
                    .font(.system(size: 12, weight: .medium))
                Text("输入增强要读取当前输入框的文字并写回译文，必须先授权。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("去授权", action: onOpenPermissionGuide)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    private var triggerSection: some View {
        section("触发") {
            HStack {
                Text("手动触发快捷键")
                    .font(.system(size: 12))
                Spacer()
                Text(settings.shortcut.displayString)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            Text("有选中文字就翻译选区；没有选中就翻译光标前最近的一句。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("打开输入增强测试", action: onOpenTestWindow)
                .padding(.top, 2)
        }
    }

    private var targetLanguageSection: some View {
        section("目标语言") {
            ForEach(Array(settings.targetLanguageCodes.enumerated()), id: \.element) { index, code in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(LanguagePreset.displayName(for: code))
                        .font(.system(size: 12))
                    Text(code.uppercased())
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        move(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)

                    Button {
                        move(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == settings.targetLanguageCodes.count - 1)

                    Button {
                        remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.targetLanguageCodes.count <= 1)
                }
                .padding(.vertical, 2)
            }

            HStack {
                Menu("添加语言") {
                    ForEach(addableLanguages, id: \.code) { language in
                        Button(language.name) { add(language.code) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(settings.targetLanguageCodes.count >= InputAssistLanguagePolicy.maximumTargetCount)

                Spacer()
                Text("最多 \(InputAssistLanguagePolicy.maximumTargetCount) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if settings.exceedsRecommendedTargetCount {
                Text("候选语言较多可能降低选择效率，建议不超过 \(InputAssistLanguagePolicy.recommendedTargetCount) 个。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("候选严格按这个顺序展示，默认高亮第一项，不会按使用频率自动重排。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var engineSection: some View {
        section("翻译引擎") {
            HStack {
                Text(engineTitle)
                    .font(.system(size: 12))
                Spacer()
                Text("在「通用」里修改")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text("所有目标语言统一使用当前引擎，暂不支持按语言分别配置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var scopeSection: some View {
        section("应用范围") {
            Picker("", selection: Binding(
                get: { settings.appScope },
                set: { settings.appScope = $0 }
            )) {
                ForEach(InputAssistAppScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if settings.appScope == .globalWithBlocklist {
                listEditor(
                    title: "黑名单",
                    hint: "每行一个，可填应用名或 Bundle ID。密码框和安全输入状态永远跳过。",
                    text: Binding(
                        get: { settings.blocklistText },
                        set: { settings.blocklistText = $0 }
                    )
                )
            } else {
                listEditor(
                    title: "仅在这些应用启用",
                    hint: "每行一个，可填应用名或 Bundle ID。",
                    text: Binding(
                        get: { settings.allowlistText },
                        set: { settings.allowlistText = $0 }
                    )
                )
            }
        }
    }

    private var cacheSection: some View {
        section("缓存") {
            HStack {
                Text("已使用 \(cacheUsageText)")
                    .font(.system(size: 12))
                Spacer()
                Button("清除翻译缓存") {
                    Task {
                        await InputAssistTranslationCacheStore.shared.clear()
                        await refreshCacheUsage()
                    }
                }
            }
            Text("清除缓存不会影响语言配置、快捷键、引擎设置和开关状态。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var debugSection: some View {
        section("调试") {
            Toggle("显示缓存命中 ⚡", isOn: Binding(
                get: { settings.showsCacheBadge },
                set: { settings.showsCacheBadge = $0 }
            ))
            .font(.system(size: 12))

            Text("候选浮层出现时按住 ⌥ 可以临时查看引擎、耗时和缓存状态。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func listEditor(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25))
                )
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var addableLanguages: [Language] {
        let existing = Set(settings.targetLanguageCodes.map { $0.lowercased() })
        return LanguagePreset.common.filter {
            $0.code != LanguagePreset.auto.code && !existing.contains($0.code.lowercased())
        }
    }

    private func add(_ code: String) {
        settings.targetLanguageCodes = settings.targetLanguageCodes + [code]
        coordinator.applyEnabledState()
    }

    private func remove(at index: Int) {
        var codes = settings.targetLanguageCodes
        guard codes.indices.contains(index), codes.count > 1 else { return }
        codes.remove(at: index)
        settings.targetLanguageCodes = codes
        coordinator.applyEnabledState()
    }

    private func move(from index: Int, by offset: Int) {
        var codes = settings.targetLanguageCodes
        let target = index + offset
        guard codes.indices.contains(index), codes.indices.contains(target) else { return }
        codes.swapAt(index, target)
        settings.targetLanguageCodes = codes
    }

    private func refreshCacheUsage() async {
        let bytes = await InputAssistTranslationCacheStore.shared.usageByteCount()
        let entries = await InputAssistTranslationCacheStore.shared.entryCount()
        let megabytes = Double(bytes) / (1024 * 1024)
        cacheUsageText = String(format: "%.1f MB（%d 条）", megabytes, entries)
    }
}
