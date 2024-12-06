//
//  ContentView.swift
//  ce
//
//  Created by A chord on 2024/12/2.
//

import SwiftUI
import Combine
import AppKit

enum Language: String, CaseIterable {
    case auto = "自动检测"
    case classicalChinese = "中文（文言文）"
    case zh = "中文（简体）"
    case en = "英语"
    case ja = "日语"
    case ko = "韩语"
    case fr = "法语"
    case de = "德语"
    case ru = "俄语"
    case es = "西班牙语"
    case it = "意大利语"
    case pt = "葡萄牙语"
    case nl = "荷兰语"
    case pl = "波兰语"
    case tr = "土耳其语"
    case ar = "阿拉伯语"
    case hi = "印地语"
    case th = "泰语"
    case vi = "越南语"
    case id = "印尼语"
    case eo = "世界语"
    
    var code: String {
        switch self {
        case .auto: return "auto"
        case .classicalChinese: return "classical-zh"
        case .zh: return "zh-CN"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        case .fr: return "fr-FR"
        case .de: return "de-DE"
        case .ru: return "ru-RU"
        case .es: return "es-ES"
        case .it: return "it-IT"
        case .pt: return "pt-PT"
        case .nl: return "nl-NL"
        case .pl: return "pl-PL"
        case .tr: return "tr-TR"
        case .ar: return "ar-SA"
        case .hi: return "hi-IN"
        case .th: return "th-TH"
        case .vi: return "vi-VN"
        case .id: return "id-ID"
        case .eo: return "eo"
        }
    }
    
    static func nameForCode(_ code: String) -> String {
        let normalizedCode = code.lowercased().split(separator: "-").first?.description ?? code.lowercased()
        switch normalizedCode {
        case "classical": return "中文（文言文）"
        case "zh": return "中文（简体）"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "ru": return "俄语"
        case "es": return "西班牙语"
        case "it": return "意大利语"
        case "pt": return "葡萄牙语"
        case "nl": return "荷兰语"
        case "pl": return "波兰语"
        case "tr": return "土耳其语"
        case "ar": return "阿拉伯语"
        case "hi": return "印地语"
        case "th": return "泰语"
        case "vi": return "越南语"
        case "id": return "印尼语"
        case "eo": return "世界语"
        case "auto": return "自动检测"
        default: return code
        }
    }
}

// 创建主题设置枚举
enum ThemeMode: String, CaseIterable {
    case light = "浅色"
    case dark = "深色"
    case system = "跟随系统"
}

class ThemeSettings: ObservableObject {
    @AppStorage("themeMode") var themeMode: ThemeMode = .system {
        didSet {
            applyTheme()
        }
    }
    
    func applyTheme() {
        switch themeMode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}

struct ContentView: View {
    @AppStorage("selectedTranslationType") private var savedTranslationType: TranslationType = .google
    @AppStorage("deeplApiKey") private var deeplApiKey: String = ""
    @AppStorage("deepSeekApiKey") private var deepSeekApiKey: String = ""
    @State private var inputText: String = ""
    @State private var translatedText: String = ""
    @State private var sourceLanguage: Language = .auto
    @State private var targetLanguage: Language = .zh
    @State private var detectedLanguage: String?
    @State private var showSettings = false
    @State private var isTranslating = false
    @State private var errorMessage: TranslationError?
    @State private var showError = false
    @State private var isGettingAIAnalysis = false
    @State private var aiAnalysis: String = ""
    @StateObject private var translationService = TranslationService.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isServiceAvailable = true
    @State private var retryCount = 0
    @State private var showCopyFeedback = false
    @State private var copyFeedbackOffset: CGFloat = 0
    @StateObject private var themeSettings = ThemeSettings()
    
    private let hotkeyManager = HotkeyManager.shared
    @State private var cancellables = Set<AnyCancellable>()
    
    private var selectedTranslationType: TranslationType {
        get { translationService.currentType }
        set { translationService.setTranslationType(newValue) }
    }
    
    private var canSwapLanguages: Bool {
        if sourceLanguage == .auto {
            return detectedLanguage != nil && !translatedText.isEmpty
        }
        return !translatedText.isEmpty
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color(NSColor.windowBackgroundColor) : Color.white
    }
    
    private var secondaryBackgroundColor: Color {
        colorScheme == .dark ? Color(NSColor.controlBackgroundColor) : Color(white: 0.98)
    }
    
    // 添加文言文选项标识
    private let classicalChineseTag = "文言文 (New!)"
    
    // 获取目标语言列表
    private func getTargetLanguages() -> [Language] {
        if selectedTranslationType == .deepSeek {
            // DeepSeek 模式下，将文言文选项放在第一位
            let languages = Language.allCases
            return [.classicalChinese] + languages.filter { $0 != .classicalChinese && $0 != .auto }
        } else {
            // 其他模式下，过滤掉文言文和自动检测选项
            return Language.allCases.filter { $0 != .classicalChinese && $0 != .auto }
        }
    }
    
    private func getTargetLanguageDisplay(_ language: Language) -> String {
        if language == .classicalChinese {
            return language.rawValue
        }
        return language.rawValue
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            HStack(spacing: 16) {
                // 翻译服务选择器
                HStack(spacing: 8) {
                    Image(systemName: selectedTranslationType == .google ? "g.circle.fill" :
                            selectedTranslationType == .deepL ? "d.circle.fill" : "brain.head.profile")
                        .font(.system(size: 18))
                        .foregroundColor(selectedTranslationType == .google ? .blue :
                                        selectedTranslationType == .deepL ? .green : .purple)
                    
                    Picker("翻译服务", selection: .init(
                        get: { selectedTranslationType },
                        set: { translationService.setTranslationType($0) }
                    )) {
                        ForEach(TranslationType.allCases, id: \.self) { type in
                            Text(type.description).tag(type)
                        }
                    }
                    .frame(width: 180)
                    .pickerStyle(MenuPickerStyle())
                    
                    // 服务状态指示器
                    if translationService.isCheckingService.contains(selectedTranslationType) {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else if let status = translationService.serviceStatus[selectedTranslationType] {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(status ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 1)
                                )
                                .shadow(color: status ? .green.opacity(0.5) : .red.opacity(0.5), radius: 2)
                            
                            if !status {
                                Button(action: {
                                    translationService.checkService(selectedTranslationType)
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("重新检查服务状态")
                            }
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(secondaryBackgroundColor)
                .cornerRadius(8)
                
                Spacer()
                
                // 主题切换按钮
                Menu {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Button(action: {
                            themeSettings.themeMode = mode
                        }) {
                            HStack {
                                Text(mode.rawValue)
                                if themeSettings.themeMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: themeSettings.themeMode == .dark ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 16))
                        .foregroundColor(themeSettings.themeMode == .dark ? .yellow : .orange)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(8)
                .background(secondaryBackgroundColor)
                .cornerRadius(8)
                
                // 设置按钮
                Button(action: {
                    showSettings.toggle()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(8)
                .background(secondaryBackgroundColor)
                .cornerRadius(8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(backgroundColor)
            
            // 权限提示条（如果需要）
            if !hotkeyManager.hasAccessibilityPermission {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("需要辅助功能权限才能使用快捷键功能")
                        .foregroundColor(.secondary)
                    Button("前往设置") {
                        hotkeyManager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }
            
            // 语言选择器
            HStack(spacing: 20) {
                // 源语言选择
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                    Text("源语言")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    Picker("", selection: $sourceLanguage) {
                        ForEach(Language.allCases, id: \.self) { language in
                            Text(language.rawValue).tag(language)
                        }
                    }
                    .frame(width: 180)
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: sourceLanguage) { oldValue, newValue in
                        if !inputText.isEmpty {
                            translate()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(secondaryBackgroundColor)
                .cornerRadius(8)
                
                // 交换按钮
                Button(action: {
                    swapLanguages()
                }) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(canSwapLanguages ? .blue : .gray)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(PlainButtonStyle())
                .background(secondaryBackgroundColor)
                .cornerRadius(8)
                .disabled(!canSwapLanguages)
                
                // 目标语言选择
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                    Text("目标语言")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    Picker("", selection: $targetLanguage) {
                        ForEach(getTargetLanguages(), id: \.self) { language in
                            if language == .classicalChinese && selectedTranslationType == .deepSeek {
                                HStack(spacing: 4) {
                                    Text(language.rawValue)
                                    Text("New!")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.blue)
                                        .cornerRadius(4)
                                        .fixedSize()
                                }
                                .tag(language)
                            } else {
                                Text(language.rawValue)
                                    .tag(language)
                            }
                        }
                    }
                    .frame(width: 180)
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: targetLanguage) { oldValue, newValue in
                        if !inputText.isEmpty {
                            translate()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(secondaryBackgroundColor)
                .cornerRadius(8)
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(backgroundColor)
            
            Divider()
                .opacity(0.5)
            
            // 输入和输出区域
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // 输入区域
                    VStack(spacing: 0) {
                        ScrollView {
                            TextEditor(text: $inputText)
                                .font(.system(size: 16))
                                .onChange(of: inputText) { oldValue, newValue in
                                    translate()
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(16)
                        }
                        .background(secondaryBackgroundColor)
                        
                        if let detected = detectedLanguage, sourceLanguage == .auto {
                            Divider()
                            HStack {
                                Image(systemName: "wand.and.stars")
                                    .foregroundColor(.blue)
                                Text("检测到: \(Language.nameForCode(detected))")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(backgroundColor)
                        }
                    }
                    .frame(width: geometry.size.width / 2)
                    
                    // 分隔线
                    Divider()
                        .opacity(0.5)
                    
                    // 输出区域
                    VStack(spacing: 0) {
                        if isTranslating {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(secondaryBackgroundColor)
                        } else {
                            VStack(spacing: 0) {
                                // 翻译结果
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack {
                                            Text(translatedText)
                                                .font(.system(size: 16))
                                                .textSelection(.enabled)
                                                .padding(16)
                                            Spacer()
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .background(secondaryBackgroundColor)
                                
                                // 底部工具栏
                                if !translatedText.isEmpty {
                                    Divider()
                                    ZStack {
                                        HStack {
                                            Spacer()
                                            Button(action: {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(translatedText, forType: .string)
                                                
                                                // 显示复制成功反馈
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                                    showCopyFeedback = true
                                                    copyFeedbackOffset = -40
                                                }
                                                
                                                // 2秒后隐藏反馈
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                    withAnimation(.easeOut(duration: 0.2)) {
                                                        showCopyFeedback = false
                                                        copyFeedbackOffset = 0
                                                    }
                                                }
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "doc.on.doc")
                                                    Text("复制")
                                                }
                                                .foregroundColor(.blue)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(6)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        
                                        // 复制成功反馈
                                        if showCopyFeedback {
                                            Text("复制成功")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(Color.black.opacity(0.8))
                                                        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 2)
                                                )
                                                .offset(y: copyFeedbackOffset)
                                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                        }
                                    }
                                    .background(backgroundColor)
                                }
                                
                                if selectedTranslationType == .deepSeek {
                                    Divider()
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: "brain.head.profile")
                                                .foregroundColor(.purple)
                                            Text("AI 理解")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            if !translatedText.isEmpty {
                                                Button(action: {
                                                    getAIAnalysis(for: translatedText)
                                                }) {
                                                    if isGettingAIAnalysis {
                                                        ProgressView()
                                                            .scaleEffect(0.6)
                                                    } else {
                                                        Image(systemName: aiAnalysis.isEmpty ? "questionmark.circle" : "arrow.clockwise")
                                                            .foregroundColor(.purple)
                                                    }
                                                }
                                                .disabled(isGettingAIAnalysis)
                                            }
                                        }
                                        if !aiAnalysis.isEmpty {
                                            Text(aiAnalysis)
                                                .font(.system(size: 14))
                                                .foregroundColor(.secondary)
                                                .lineLimit(nil)
                                                .textSelection(.enabled)
                                        } else if !isGettingAIAnalysis && !translatedText.isEmpty {
                                            Text("点击问号图标获取 AI 理解分析")
                                                .font(.system(size: 14))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(backgroundColor)
                                }
                            }
                        }
                    }
                    .frame(width: geometry.size.width / 2)
                }
            }
            .background(backgroundColor)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("翻译错误", isPresented: $showError) {
            Group {
                Button("确定", role: .cancel) {}
                if case .missingApiKey = errorMessage {
                    Button("前往设置") {
                        showSettings = true
                    }
                }
            }
        } message: {
            if let error = errorMessage {
                Text(error.localizedDescription)
            } else {
                Text("未知错误")
            }
        }
        .onAppear {
            print("ContentView 出现")
            // 初始化时使用保存的设置
            translationService.setDeepLApiKey(deeplApiKey)
            translationService.setDeepSeekApiKey(deepSeekApiKey)
            translationService.setTranslationType(savedTranslationType)
            translationService.checkAllServices()
            
            // 注册翻译回调
            hotkeyManager.register { [self] in
                print("翻译回调被触发")
                if let clipboardText = NSPasteboard.general.string(forType: .string) {
                    print("设置输入文本：\(clipboardText)")
                    inputText = clipboardText
                    translate()
                }
            }
        }
    }
    
    private func translate() {
        guard !inputText.isEmpty else {
            translatedText = ""
            aiAnalysis = ""
            return
        }
        
        isTranslating = true
        aiAnalysis = ""
        
        translationService.translate(
            text: inputText,
            sourceLang: sourceLanguage == .auto ? "auto" : sourceLanguage.code,
            targetLang: targetLanguage.code
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { completion in
                isTranslating = false
                if case .failure(let error) = completion {
                    errorMessage = error
                    showError = true
                }
            },
            receiveValue: { result in
                translatedText = result.text
                if sourceLanguage == .auto {
                    detectedLanguage = result.detectedLanguage
                }
            }
        )
        .store(in: &cancellables)
    }
    
    private func getAIAnalysis(for text: String) {
        isGettingAIAnalysis = true
        aiAnalysis = ""
        
        let prompt = """
        请分析这段文本，从以下几个方面简洁地回答：
        1. 文本的主要含义
        2. 特殊的语言表达或文化含义（如果有）
        3. 双关语或隐含意思（如果有）
        
        请直接描述，不要输出标题和序号，用简单的语言连贯地表达：
        
        文本：\(text)
        """
        
        translationService.getAISuggestion(prompt: prompt)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    isGettingAIAnalysis = false
                    if case .failure(let error) = completion {
                        errorMessage = error
                        showError = true
                    }
                },
                receiveValue: { analysis in
                    // 移除可能的标题和序号
                    let cleanedAnalysis = analysis
                        .replacingOccurrences(of: "**.*?**", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\\d+\\.\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    aiAnalysis = cleanedAnalysis
                }
            )
            .store(in: &cancellables)
    }
    
    private func swapLanguages() {
        guard canSwapLanguages else { return }
        
        // 定新的源语言：使用当前的目标语
        let newSourceLang = targetLanguage
        
        // 确定新的目标语言
        let newTargetLang: Language
        if sourceLanguage == .auto {
            // 如果当前是自动检测，且已检测出语言，使用检测到的语言
            if let detectedCode = detectedLanguage {
                // 将检测到的语言代码转换为 Language 枚举
                let code = detectedCode.split(separator: "-").first?.description ?? detectedCode
                if let detectedLang = Language.allCases.first(where: { $0.code.lowercased().starts(with: code.lowercased()) }) {
                    newTargetLang = detectedLang
                } else {
                    // 如果无法匹配检测到的语言，使用英语作为后备
                    newTargetLang = .en
                }
            } else {
                // 如果没有检测到语言，保持目标语言不变
                return
            }
        } else {
            // 如果不是自动检测，使用当前的源语言
            newTargetLang = sourceLanguage
        }
        
        // 交换语言
        sourceLanguage = newSourceLang
        targetLanguage = newTargetLang
        
        // 交换文本
        let tempText = inputText
        inputText = translatedText
        translatedText = tempText
        
        // 清除检测到的语言信息
        detectedLanguage = nil
        
        // 如果有新的输入文本，触发翻译
        if !inputText.isEmpty {
            translate()
        }
    }
}

#Preview {
    ContentView()
}
