import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// OCR：使用 Apple Vision 识别图片里的文字。
//
// 这里默认“自动识别语言”。为了提高命中率，我们提供一组常见语言作为候选。
// 后续如果你希望“按提示源语言优化 OCR”，也可以在这里加一个参数。

enum VisionOCRService {
    struct OCRLine: Identifiable, Hashable {
        let id: UUID = UUID()
        let text: String
        // Vision 标准化坐标：0~1，原点在左下角。
        let boundingBox: CGRect
    }

    @MainActor
    static func recognizeText(from image: NSImage) async -> String {
        await recognizeText(from: image, preferredLanguageCode: LanguagePreset.auto.code)
    }

    @MainActor
    static func recognizeText(from image: NSImage, preferredLanguageCode: String) async -> String {
        let lines = await recognizeLines(from: image, preferredLanguageCode: preferredLanguageCode)
        return lines.map { $0.text }.joined(separator: "\n")
    }

    @MainActor
    static func recognizeLines(from image: NSImage, preferredLanguageCode: String) async -> [OCRLine] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let recognitionLanguages = visionLanguages(for: preferredLanguageCode)

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let items: [OCRLine] = observations.compactMap { obs in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return nil }
                    return OCRLine(text: trimmed, boundingBox: obs.boundingBox)
                }

                // Vision 结果不是严格按阅读顺序的；这里做一个近似排序：先按 y(从上到下)，再按 x。
                let sorted = items.sorted { a, b in
                    let ay = 1 - a.boundingBox.midY
                    let by = 1 - b.boundingBox.midY
                    if abs(ay - by) > 0.02 {
                        return ay < by
                    }
                    return a.boundingBox.minX < b.boundingBox.minX
                }

                continuation.resume(returning: postProcess(lines: sorted, preferredLanguageCode: preferredLanguageCode))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008

            if #available(macOS 13.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            request.recognitionLanguages = recognitionLanguages

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let processed = preprocess(cgImage: cgImage) ?? cgImage
                    let handler = VNImageRequestHandler(cgImage: processed, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private static func postProcess(lines: [OCRLine], preferredLanguageCode: String) -> [OCRLine] {
        if lines.isEmpty { return [] }

        let shouldApplySpanishFix = shouldApplySpanishFix(preferredLanguageCode: preferredLanguageCode, lines: lines)
        let shouldApplyRussianFix = shouldApplyRussianFix(preferredLanguageCode: preferredLanguageCode)

        let normalized = lines.map {
            var t = normalizeText($0.text)
            if shouldApplySpanishFix {
                t = fixSpanishArtifacts(t)
            }
            if shouldApplyRussianFix {
                t = fixRussianArtifacts(t)
            }
            return OCRLine(text: t, boundingBox: $0.boundingBox)
        }

        var deduped: [OCRLine] = []
        deduped.reserveCapacity(normalized.count)
        for line in normalized {
            guard !line.text.isEmpty else { continue }
            if let last = deduped.last {
                if line.text == last.text {
                    continue
                }
                if line.text.hasPrefix(last.text), line.text.count >= last.text.count + 8 {
                    let mergedBox = union(a: last.boundingBox, b: line.boundingBox)
                    deduped[deduped.count - 1] = OCRLine(text: line.text, boundingBox: mergedBox)
                    continue
                }
                if last.text.hasPrefix(line.text), last.text.count >= line.text.count + 8 {
                    continue
                }
            }
            deduped.append(line)
        }

        var merged: [OCRLine] = []
        merged.reserveCapacity(deduped.count)

        for line in deduped {
            if var last = merged.last, shouldMerge(last: last, next: line) {
                let joined = joinWrapped(lastText: last.text, nextText: line.text)
                let mergedBox = union(a: last.boundingBox, b: line.boundingBox)
                last = OCRLine(text: joined, boundingBox: mergedBox)
                merged[merged.count - 1] = last
            } else {
                merged.append(line)
            }
        }

        return merged
    }

    private static func shouldApplyRussianFix(preferredLanguageCode: String) -> Bool {
        // 仅当用户明确选择俄语时才启用俄语修复。
        // 否则会把英文（尤其是代码/缩写）错误映射成西里尔字母，导致“英文变俄语字形”。
        return preferredLanguageCode == "ru" || preferredLanguageCode.hasPrefix("ru-")
    }

    private static func fixRussianArtifacts(_ text: String) -> String {
        var t = text

        // 偶发：OCR 会把其它语言字符混入俄语（例如汉字）。在俄语模式下先移除，避免影响翻译与语言识别。
        t = regexReplace(t, pattern: "[\\p{Han}]", replacement: "", options: [])

        t = regexReplace(t, pattern: "\\bnpnBeT\\b", replacement: "Привет", options: [.caseInsensitive])
        t = regexReplace(t, pattern: "\\b3TO\\b", replacement: "Это", options: [.caseInsensitive])

        let parts = t.components(separatedBy: .whitespacesAndNewlines)
        if parts.isEmpty { return normalizeText(t) }

        let mapped = parts.map { fixRussianTokenIfNeeded($0) }.joined(separator: " ")
        return normalizeText(mapped)
    }

    private static func looksLikeRussianCyrillicMisreadWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        if w.count < 4 { return false }
        if w.contains("-") { return false }
        if w.contains("/") { return false }
        if w.contains("\\") { return false }
        if w.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return false }

        let mappable: Set<Character> = [
            "A", "B", "C", "E", "H", "K", "M", "O", "P", "T", "X", "Y",
            "N", "U", "L", "I",
            "a", "c", "e", "o", "p", "x", "y", "k", "m", "t",
            "n", "u", "l", "i",
            "3", "0"
        ]

        let chars = Array(w)
        let m = chars.filter { mappable.contains($0) }.count
        if m < 3 { return false }
        return Double(m) / Double(chars.count) >= 0.7
    }

    private static func fixRussianTokenIfNeeded(_ token: String) -> String {
        if token.contains("-") { return token }

        let chars = Array(token)
        var start = 0
        var end = chars.count

        while start < end {
            let s = chars[start].unicodeScalars
            if let u = s.first, CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) {
                break
            }
            start += 1
        }
        while end > start {
            let s = chars[end - 1].unicodeScalars
            if let u = s.first, CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) {
                break
            }
            end -= 1
        }

        if start >= end { return token }

        let prefix = String(chars.prefix(start))
        let core = String(chars[start..<end])
        let suffix = String(chars.suffix(chars.count - end))

        if core.contains("-") { return token }
        if core.contains("/") { return token }
        if core.contains("\\") { return token }
        if core == core.uppercased(), core.count <= 6 { return token }
        if !looksLikeRussianCyrillicMisreadWord(core) { return token }

        let map: [Character: Character] = [
            "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К", "M": "М", "O": "О", "P": "Р", "T": "Т", "X": "Х", "Y": "У",
            "N": "П", "U": "И", "L": "Л", "I": "И",
            "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х", "y": "у", "k": "к", "m": "м", "t": "т",
            "n": "п", "u": "и", "l": "л", "i": "и",
            "3": "Э", "0": "О"
        ]

        let mappedCore = String(core.map { map[$0] ?? $0 })

        // 将全大写/混合大小写的“俄语词”尽量规整成人类常见书写：首字母大写，其余小写。
        // 例：ATOH -> Атон
        let normalizedCore: String
        if mappedCore.count >= 4, mappedCore.range(of: "[А-Яа-я]", options: .regularExpression) != nil {
            let lower = mappedCore.lowercased()
            if let first = lower.first {
                normalizedCore = String(first).uppercased() + lower.dropFirst()
            } else {
                normalizedCore = mappedCore
            }
        } else {
            normalizedCore = mappedCore
        }

        return prefix + normalizedCore + suffix
    }

    private static func shouldApplySpanishFix(preferredLanguageCode: String, lines: [OCRLine]) -> Bool {
        if preferredLanguageCode == "es" || preferredLanguageCode.hasPrefix("es-") {
            return true
        }

        // 用户选 auto 时，根据文本内容做一个极轻量判断。
        // 目标：仅在“很像西班牙语”时才启用，避免误伤其它语言。
        let sample = lines.prefix(12).map { $0.text }.joined(separator: " ")
        let lower = sample.lowercased()
        if lower.contains("hola") { return true }
        if lower.contains("necesitas") { return true }
        if lower.contains("recibimos") { return true }
        if lower.contains("usted") { return true }
        if lower.contains("saludos") { return true }
        return false
    }

    private static func fixSpanishArtifacts(_ text: String) -> String {
        var t = text

        // 统一常见全角标点/中文标点。
        t = t.replacingOccurrences(of: "？", with: "?")
        t = t.replacingOccurrences(of: "，", with: ",")
        t = t.replacingOccurrences(of: "。", with: ".")

        // Vision OCR 有时把倒问号 ¿ 识别成 i（尤其在行首）。
        t = regexReplace(t, pattern: "^\\s*i([A-ZÁÉÍÓÚÑ])", replacement: "¿$1", options: [.caseInsensitive])
        // 有些场景会变成 iverdad/iverdad?
        t = regexReplace(t, pattern: "\\biverdad\\b", replacement: "¿verdad", options: [.caseInsensitive])

        // 修正常见疑问词的重音（只在已经有 ¿ 的情况下更安全）。
        t = t.replacingOccurrences(of: "¿Cuantas", with: "¿Cuántas")
        t = t.replacingOccurrences(of: "¿cuantas", with: "¿cuántas")
        t = t.replacingOccurrences(of: "¿Cual", with: "¿Cuál")
        t = t.replacingOccurrences(of: "¿cual", with: "¿cuál")

        // 修正 grúa（吊车）：OCR 常把 ú 丢掉或把 u 识别成 i。
        t = regexReplace(t, pattern: "\\bgria\\b", replacement: "grúa", options: [.caseInsensitive])
        t = regexReplace(t, pattern: "\\bgrua\\b", replacement: "grúa", options: [.caseInsensitive])

        // 如果出现 "¿verdad" 且句末缺问号，补一个。
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("¿verdad") {
            t = trimmed + "?"
        }

        return normalizeText(t)
    }

    private static func regexReplace(
        _ text: String,
        pattern: String,
        replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        do {
            let re = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        } catch {
            return text
        }
    }

    private static func normalizeText(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldMerge(last: OCRLine, next: OCRLine) -> Bool {
        let lastText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lastText.isEmpty || nextText.isEmpty { return false }

        if endsWithSentencePunctuation(lastText) { return false }

        let nearRight = last.boundingBox.maxX >= 0.86
        let nearLeft = next.boundingBox.minX <= 0.16
        if !(nearRight && nearLeft) { return false }

        let gap = last.boundingBox.minY - next.boundingBox.maxY
        let avgH = (last.boundingBox.height + next.boundingBox.height) / 2
        if gap > max(0.02, avgH * 0.75) {
            return false
        }

        return true
    }

    private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".?!。？！；;:".contains(last)
    }

    private static func joinWrapped(lastText: String, nextText: String) -> String {
        let a = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = nextText.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasSuffix("-") {
            return String(a.dropLast()) + b
        }
        return a + " " + b
    }

    private static func union(a: CGRect, b: CGRect) -> CGRect {
        let minX = min(a.minX, b.minX)
        let minY = min(a.minY, b.minY)
        let maxX = max(a.maxX, b.maxX)
        let maxY = max(a.maxY, b.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func visionLanguages(for appLanguageCode: String) -> [String] {
        // 只给少量候选语言：越少越不容易误判（同时速度更快）。
        // 如果用户明确选了源语言，就只给该语言相关的 Vision locale。
        switch appLanguageCode {
        case "zh-CN":
            return ["zh-Hans"]
        case "zh-TW":
            return ["zh-Hant"]
        case "en":
            return ["en-US"]
        case "ja":
            return ["ja-JP"]
        case "ko":
            return ["ko-KR"]
        case "ru":
            return ["ru-RU"]
        case "fr":
            return ["fr-FR"]
        case "de":
            return ["de-DE"]
        case "es":
            return ["es-ES"]
        case "vi":
            return ["vi-VN"]
        case "pt":
            return ["pt-BR", "pt-PT"]
        case "it":
            return ["it-IT"]
        case "auto":
            fallthrough
        default:
            // 默认候选不包含俄语：避免把英文/代码识别成“俄语字形”。
            return ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "vi-VN"]
        }
    }

    private static func preprocess(cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)

        // 对小字效果明显：先 2x 放大再做对比度/锐化。
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = input
        scale.scale = 2.0
        scale.aspectRatio = 1.0

        let controls = CIFilter.colorControls()
        controls.inputImage = scale.outputImage
        controls.saturation = 0.0
        controls.contrast = 1.25
        controls.brightness = 0.02

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controls.outputImage
        sharpen.sharpness = 0.4

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let out = sharpen.outputImage else { return nil }
        return context.createCGImage(out, from: out.extent)
    }
}
