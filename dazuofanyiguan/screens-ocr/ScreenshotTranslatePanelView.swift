import AppKit
import SwiftUI

struct ScreenshotTranslatePanelView: View {
    let initialOCRText: String
    let defaultTargetLanguageCode: String
    let onCancel: () -> Void
    let onTranslate: (_ source: String, _ target: String, _ phase: ((String) -> Void)?) async -> Result<String, Error>
    let onTranslated: (String) -> Void

    @State private var sourceLanguageCode: String = LanguagePreset.auto.code
    @State private var targetLanguageCode: String

    @State private var isTranslating: Bool = false
    @State private var phaseText: String? = nil

    @State private var translatedText: String? = nil

    init(
        initialOCRText: String,
        defaultTargetLanguageCode: String,
        onCancel: @escaping () -> Void,
        onTranslate: @escaping (_ source: String, _ target: String, _ phase: ((String) -> Void)?) async -> Result<String, Error>,
        onTranslated: @escaping (String) -> Void
    ) {
        self.initialOCRText = initialOCRText
        self.defaultTargetLanguageCode = defaultTargetLanguageCode
        self.onCancel = onCancel
        self.onTranslate = onTranslate
        self.onTranslated = onTranslated
        _targetLanguageCode = State(initialValue: defaultTargetLanguageCode)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                LanguageSearchPicker(
                    title: "源语言",
                    allowAuto: true,
                    options: LanguagePreset.common,
                    selection: $sourceLanguageCode
                )

                LanguageSearchPicker(
                    title: "目标语言",
                    allowAuto: false,
                    options: LanguagePreset.common,
                    selection: $targetLanguageCode
                )

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OCR 结果")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(initialOCRText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 88)
                .dsCard()
            }

            if let translatedText {
                VStack(alignment: .leading, spacing: 8) {
                    Text("译文")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(translatedText)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 88)
                    .dsCard()
                }
            }

            HStack(spacing: 10) {
                Button(isTranslating ? "正在翻译…" : (translatedText == nil ? "开始翻译" : "重新翻译")) {
                    Task { @MainActor in
                        await translateNow()
                    }
                }
                .disabled(isTranslating)

                Button(translatedText == nil ? "复制原文" : "复制译文") {
                    let text = translatedText ?? initialOCRText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }

                Spacer(minLength: 0)

                Button("取消") {
                    onCancel()
                }
            }

            if isTranslating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(phaseText ?? "正在等待响应")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
    }

    @MainActor
    private func translateNow() async {
        isTranslating = true
        phaseText = "正在准备请求"
        defer {
            isTranslating = false
            phaseText = nil
        }

        let result = await onTranslate(sourceLanguageCode, targetLanguageCode) { phase in
            Task { @MainActor in
                phaseText = phase
            }
        }

        switch result {
        case .success(let text):
            translatedText = text
            onTranslated(text)
        case .failure:
            translatedText = nil
        }
    }
}
