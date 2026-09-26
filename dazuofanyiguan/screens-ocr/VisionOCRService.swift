import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// OCR：使用 Apple Vision 识别图片里的文字，再把折行的行拼回段落（见 OCRParagraphGrouper）。
//
// 源语言选「自动检测」时交给 Vision 自己判断书写系统；手动指定时只用那一种语言。
// 两者不能同时开：自动识别会盖过指定的语言，纯汉字的日文照样被认成繁体中文。

enum VisionOCRService {
    struct OCRLine: Identifiable, Hashable {
        let id: UUID = UUID()
        let text: String
        // Vision 标准化坐标：0~1，原点在左下角。
        let boundingBox: CGRect
    }

    /// 折行拼回来的一段文字。翻译按段进行，回贴也按段排版。
    struct OCRBlock: Identifiable, Hashable {
        let id: UUID = UUID()
        let text: String
        /// 组成这一段的各行，从上到下。
        let lines: [OCRLine]

        /// 各行外接框的并集（Vision 标准化坐标）。
        var boundingBox: CGRect {
            guard let first = lines.first else { return .zero }
            return lines.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
        }
    }

    @MainActor
    static func recognizeBlocks(from image: NSImage, languageCode: String) async -> [OCRBlock] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let visionLanguage = visionLanguage(for: languageCode)
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                configure(request, visionLanguage: visionLanguage)

                // 不用 completionHandler：perform 抛错时它照样会被回调（实测），
                // 回调里和 catch 里各 resume 一次会直接崩。只在 perform 返回之后读结果。
                let processed = preprocess(cgImage: cgImage) ?? cgImage
                let handler = VNImageRequestHandler(cgImage: processed, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }

                let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let normalized = normalizeText(text)
                    if normalized.isEmpty { return nil }
                    return OCRLine(text: normalized, boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: OCRParagraphGrouper.group(lines, imageSize: imageSize))
            }
        }
    }

    static func configure(_ request: VNRecognizeTextRequest, visionLanguage: String?) {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        request.revision = VNRecognizeTextRequestRevision3

        if let visionLanguage {
            request.recognitionLanguages = [visionLanguage]
            request.automaticallyDetectsLanguage = false
        } else {
            request.automaticallyDetectsLanguage = true
        }
    }

    /// 应用语言代码 → Vision 识别语言。返回 nil 表示交给 Vision 自动识别
    /// （选了「自动检测」，或 Vision 不认识这门语言）。
    static func visionLanguage(for appLanguageCode: String) -> String? {
        visionLanguageByAppCode[appLanguageCode]
    }

    private static let visionLanguageByAppCode: [String: String] = [
        "zh-CN": "zh-Hans",
        "zh-TW": "zh-Hant",
        "en": "en-US",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "fr": "fr-FR",
        "de": "de-DE",
        "it": "it-IT",
        "es": "es-ES",
        "pt": "pt-BR",
        "nl": "nl-NL",
        "sv": "sv-SE",
        "da": "da-DK",
        "no": "no-NO",
        "pl": "pl-PL",
        "cs": "cs-CZ",
        "ro": "ro-RO",
        "uk": "uk-UA",
        "ru": "ru-RU",
        "tr": "tr-TR",
        "ar": "ar-SA",
        "th": "th-TH",
        // Vision 的越南语代码是 vi-VT。写成 vi-VN 不会报错，只会被悄悄忽略。
        "vi": "vi-VT",
        "id": "id-ID",
        "ms": "ms-MY"
    ]

    /// 截图翻译可选的源语言：自动检测 + 本机 Vision 实际支持的语言。
    /// 按系统实时查询：旧系统支持的语言更少，列出来也认不出。
    static let selectableSourceLanguages: [Language] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])

        let recognizable = LanguagePreset.common.filter { language in
            guard let visionCode = visionLanguageByAppCode[language.code] else { return false }
            // 查不到支持列表不等于都不支持：宁可多列几个，也别把整个选择器清空。
            return supported.isEmpty || supported.contains(visionCode)
        }
        return [LanguagePreset.auto] + recognizable
    }()

    private static func normalizeText(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    // 高分屏物理像素截图再无上限 2x 会爆内存；只对小图放大，大图保持或下采样。
    private static let maxUpscaleLongestEdge: CGFloat = 1800
    private static let maxProcessedLongestEdge: CGFloat = 3600
    private static let maxProcessedPixelCount: CGFloat = 12_000_000

    /// 送进 Vision 之前的缩放倍数。
    static func preprocessScale(pixelWidth: CGFloat, pixelHeight: CGFloat) -> CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }

        let longestEdge = max(pixelWidth, pixelHeight)
        let pixelCount = pixelWidth * pixelHeight

        if longestEdge <= maxUpscaleLongestEdge,
           pixelCount * 4 <= maxProcessedPixelCount,
           longestEdge * 2 <= maxProcessedLongestEdge {
            return 2
        }
        if longestEdge > maxProcessedLongestEdge || pixelCount > maxProcessedPixelCount {
            let edgeScale = maxProcessedLongestEdge / longestEdge
            let pixelScale = sqrt(maxProcessedPixelCount / pixelCount)
            return min(1, edgeScale, pixelScale)
        }
        return 1
    }

    /// 只缩放，不做灰度 / 对比度 / 锐化。那几步实测在浅灰字和图片背景上会凭空多出
    /// 「|」「.」之类的杂字；放大本身则对非 Retina 屏上的小字有帮助，所以只留放大。
    private static func preprocess(cgImage: CGImage) -> CGImage? {
        let scale = preprocessScale(
            pixelWidth: CGFloat(cgImage.width),
            pixelHeight: CGFloat(cgImage.height)
        )
        if abs(scale - 1) < 0.001 { return cgImage }

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: cgImage)
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { return nil }
        return sharedCIContext.createCGImage(output, from: output.extent)
    }
}
