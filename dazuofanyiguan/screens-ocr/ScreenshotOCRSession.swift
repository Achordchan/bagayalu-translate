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
    /// 回贴图还在后台画（刚补上一批译文、或者刚翻完）。画完之前 translatedImage 是上一批的，或者还是 nil。
    @Published var overlayRenderPending: Bool = false

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

    /// 一次回贴渲染的结果：画出来了换上新图；画不出来就清掉旧图（旧图只有前几批的译文），
    /// 让界面退回卡片列出最新的译文。
    func applyOverlayRender(_ image: NSImage?) {
        translatedImage = image
        overlayUnavailable = image == nil
    }

    /// 「钉到屏幕」「完成」拿走的那张图。
    struct ExportImage {
        enum Kind: Equatable {
            /// 没翻译（或者翻译失败、换了源语言、没有要翻的字）：选区里是原截图。
            case original
            /// 翻完了：贴了译文的图。
            case translated
            /// 翻完了，但回贴图没画出来（界面退回文字卡片），只能给原截图，要跟用户说一声。
            case originalBecauseOverlayFailed
        }

        let image: NSImage
        let kind: Kind
    }

    /// 识别、翻译进行中，或者回贴图还在画的时候，不能「钉到屏幕」「完成」：
    /// 钉上去的图不会再更新，这时候拿走的是翻了一半、或者上一批的图。
    var canExport: Bool {
        stage != .ocrRunning && stage != .translating && !overlayRenderPending
    }

    /// 选区里显示的是哪张就给哪张：翻完了给贴了译文的图，否则给原截图。
    /// 现在不能拿（见 `canExport`）、或者还没截到图时为 nil。
    func imageForExport() -> ExportImage? {
        guard canExport, let capturedImage else { return nil }
        guard stage == .translated else { return ExportImage(image: capturedImage, kind: .original) }
        if let translatedImage {
            return ExportImage(image: translatedImage, kind: .translated)
        }
        return ExportImage(image: capturedImage, kind: overlayUnavailable ? .originalBecauseOverlayFailed : .original)
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
