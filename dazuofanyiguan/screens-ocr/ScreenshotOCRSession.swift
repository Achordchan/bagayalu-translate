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

    @Published var sourceLanguageCode: String = LanguagePreset.auto.code
    @Published var targetLanguageCode: String = "en"

    @Published var ocrText: String = ""
    @Published var translatedText: String = ""

    // 用户框选完成后先缓存截图；点击“翻译”时再 OCR + 翻译。
    @Published var capturedImage: NSImage? = nil

    @Published var didExtractTextToPasteboard: Bool = false

    @Published var ocrLines: [VisionOCRService.OCRLine] = []
    @Published var translatedLines: [VisionOCRService.OCRLine] = []

    @Published var frozenBackgrounds: [FrozenBackground] = []

    @Published var showCompare: Bool = false

    @Published var hudToast: HUDToast? = nil

    init(sourceLanguageCode: String, targetLanguageCode: String) {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
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
