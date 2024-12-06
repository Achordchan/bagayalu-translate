import SwiftUI

struct SettingsView: View {
    @AppStorage("deeplApiKey") private var deeplApiKey: String = ""
    @AppStorage("deepSeekApiKey") private var deepSeekApiKey: String = ""
    @AppStorage("deepSeekPrompt") private var deepSeekPrompt: String = "You are a professional translator. Please translate the following text accurately while maintaining its original meaning and style:"
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var hotkeyManager = HotkeyManager.shared
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color(NSColor.windowBackgroundColor) : Color.white
    }
    
    private var secondaryBackgroundColor: Color {
        colorScheme == .dark ? Color(NSColor.controlBackgroundColor) : Color(white: 0.98)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            ScrollView {
                VStack(spacing: 24) {
                    deeplSettingsView
                    deepSeekSettingsView
                    infoView
                }
                .padding()
            }
        }
        .frame(width: 560, height: 680)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var headerView: some View {
        HStack {
            Text("翻译设置")
                .font(.system(size: 20, weight: .medium))
            Spacer()
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    
    private var deeplSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "d.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                Text("DeepL API")
                    .font(.headline)
            }
            
            SecureField("请输入 DeepL API Key", text: $deeplApiKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: deeplApiKey) { oldValue, newValue in
                    TranslationService.shared.setDeepLApiKey(newValue)
                }
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(10)
        .shadow(radius: 1)
    }
    
    private var deepSeekSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
                Text("DeepSeek AI")
                    .font(.headline)
            }
            
            SecureField("请输入 DeepSeek API Key", text: $deepSeekApiKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: deepSeekApiKey) { oldValue, newValue in
                    TranslationService.shared.setDeepSeekApiKey(newValue)
                }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("自定义提示词")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextEditor(text: $deepSeekPrompt)
                    .font(.system(.body))
                    .frame(height: 100)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .onChange(of: deepSeekPrompt) { oldValue, newValue in
                        TranslationService.shared.setDeepSeekPrompt(newValue)
                    }
            }
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(10)
        .shadow(radius: 1)
    }
    
    private var infoView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                Text("使用说明")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "link", color: .green, text: "DeepL API Key 可以从 DeepL 开发者平台获取")
                InfoRow(icon: "key.fill", color: .purple, text: "DeepSeek API Key 可以从 DeepSeek AI 平台获取")
                InfoRow(icon: "text.word.spacing", color: .orange, text: "DeepSeek Prompt 可以自定义翻译指令，帮助AI更好地理解翻译需求")
                InfoRow(icon: "keyboard", color: .blue, text: "使用 Command+C+C（按住Command键连按两次C）快速呼出翻译")
                Divider()
                    .padding(.vertical, 4)
                Text("作者信息")
                    .font(.headline)
                    .foregroundColor(.secondary)
                InfoRow(icon: "person.circle.fill", color: .blue, text: "Achord")
                InfoRow(icon: "phone.circle.fill", color: .green, text: "13160235855")
                    .textSelection(.enabled)
                InfoRow(icon: "envelope.circle.fill", color: .orange, text: "achordchan@gmail.com")
                    .textSelection(.enabled)
            }
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(10)
        .shadow(radius: 1)
    }
}

struct InfoRow: View {
    let icon: String
    let color: Color
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }
} 