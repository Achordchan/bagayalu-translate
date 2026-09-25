import AppKit
import Foundation

@MainActor
final class ScreenshotOCRSession: ObservableObject {
    struct HUDToast: Identifiable {
        enum Style {
            case success
            case info
            case warning
            case error
        }

        let id = UUID()
        let style: Style
        let message: String
    }
    struct FrozenBackground: Identifiable, Hashable {
        let id: UUID = UUID()
        let image: NSImage
        // contentView 坐标（左下原点），相对于 selectionWindow 的 content。
        let rect: CGRect
    }
    enum Stage: Equatable {
        case selecting
        case selected
        case ocrRunning
        case ocrReady
        case translating
        case translated
        case failed(String)
    }

    @Published var stage: Stage = .selecting

    // contentView 坐标（window 内容坐标系）
    @Published var selectionRect: CGRect = .zero

    @Published var sourceLanguageCode: String = LanguagePreset.auto.code {
        didSet {
            guard sourceLanguageCode != oldValue else { return }
            discardRecognitionForNewSourceLanguage()
        }
    }
    @Published var targetLanguageCode: String = "en"

    @Published var ocrText: String = ""
    @Published var translatedText: String = ""

    // 用户框选完成后先缓存截图；点击“翻译”时再 OCR + 翻译。
    @Published var capturedImage: NSImage? = nil

    @Published var didExtractTextToPasteboard: Bool = false

    /// 识别结果：折行已拼回段落，按阅读顺序排列。
    @Published var ocrBlocks: [VisionOCRService.OCRBlock] = []
    /// 各段的译文（按段落 id）。不用翻的段落存原文；翻译进行中会一批批补上。
    @Published var translations: [UUID: String] = [:]
    /// 回贴好的整张图：原截图上抹掉原文、按原位置画上译文。翻译进行中每翻完一批更新一次，还没画出来时为 nil。
    @Published var translatedImage: NSImage? = nil
    /// 回贴图画不出来（极少见），界面退回用卡片列出译文。
    @Published var overlayUnavailable: Bool = false

    @Published var frozenBackgrounds: [FrozenBackground] = []

    @Published var showCompare: Bool = false

    @Published var hudToast: HUDToast? = nil

    /// 选区或源语言一变就 +1。识别、翻译都是异步的，回来时对不上就丢弃结果，
    /// 免得旧选区的结果盖掉新选区。
    private(set) var generation: Int = 0

    init(sourceLanguageCode: String, targetLanguageCode: String) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }

    /// 清掉截图和所有识别、翻译结果（重新框选、清空选区时用）。
    func resetResults() {
        generation += 1
        ocrText = ""
        translatedText = ""
        ocrBlocks = []
        translations = [:]
        translatedImage = nil
        overlayUnavailable = false
        capturedImage = nil
        didExtractTextToPasteboard = false
        showCompare = false
    }

    /// 换了源语言，已有的识别结果就作废了（手动指定语言就是为了纠正自动识别认错的字），
    /// 保留截图，下次点「翻译」重新识别。「未识别到文字」之后换语言也能直接重试。
    private func discardRecognitionForNewSourceLanguage() {
        guard stage != .selecting else { return }

        generation += 1
        ocrText = ""
        translatedText = ""
        ocrBlocks = []
        translations = [:]
        translatedImage = nil
        overlayUnavailable = false
        didExtractTextToPasteboard = false
        showCompare = false
        if capturedImage != nil {
            stage = .selected
        }
    }

    func showHUD(_ message: String, style: HUDToast.Style = .info, duration: TimeInterval = 1.8) {
        let toast = HUDToast(style: style, message: message)
        hudToast = toast
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self.hudToast?.id == toast.id {
                self.hudToast = nil
            }
        }
    }
}
