import AppKit
import Foundation
import NaturalLanguage

@MainActor
final class ScreenshotOCRCoordinator: ObservableObject {
    @Published private(set) var isRunning: Bool = false

    private var session: ScreenshotOCRSession?
    private var selectionWindow: ScreenshotSelectionWindow?
    private var panelWindow: ScreenshotTranslatePanelWindow?
    private var overlayWindow: TranslationOverlayWindow?

    private var pinnedWindows: [PinnedScreenshotWindow] = []

    private var globalKeyMonitor: Any?

    private var previousFrontmostAppPID: pid_t?

    func start(settings: AppSettings, log: LogStore, toast: ToastCenter) {
        if isRunning {
            cancelAll()
        }
        isRunning = true

        Task { @MainActor in
            // 1) 全局快捷键依赖辅助功能权限（CGEventTap）。没有这个权限，用户会感觉“按了没反应”。
            // 这里在真正开始前做一次友好检查，引导用户去系统设置授权。
            if !AXIsProcessTrusted() {
                toast.show("需要开启“辅助功能”权限才能使用快捷键（Cmd+X+X）", style: .warning)
                GlobalHotkeyMonitor.openAccessibilitySettings()
                cancelAll()
                return
            }

            // 2) 截图依赖屏幕录制权限。
            if !ScreenCapturePermission.hasPermission() {
                toast.show("需要开启“屏幕录制”权限才能截图翻译", style: .warning)
                ScreenCapturePermission.openScreenRecordingSettings()
                cancelAll()
                return
            }

            let canCapture = await ScreenCapturePermission.ensurePermission()
            guard canCapture else {
                toast.show("需要屏幕录制权限才能进行截图翻译", style: .warning)
                cancelAll()
                return
            }

            var frozen: [ScreenshotOCRSession.FrozenBackground] = []
            if settings.screenshotFreezeBackgroundEnabled {
                frozen = await captureFrozenBackgrounds(log: log)
            }

            presentSelection(settings: settings, log: log, toast: toast, frozenBackgrounds: frozen)
        }
    }

    func cancelAll() {
        session = nil
        selectionWindow?.close()
        selectionWindow = nil

        panelWindow?.close()
        panelWindow = nil

        overlayWindow?.close()
        overlayWindow = nil

        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }

        if let pid = previousFrontmostAppPID,
           pid != NSRunningApplication.current.processIdentifier,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
        }
        previousFrontmostAppPID = nil

        isRunning = false
    }

    private func presentSelection(settings: AppSettings, log: LogStore, toast: ToastCenter, frozenBackgrounds: [ScreenshotOCRSession.FrozenBackground]) {
        panelWindow?.close()
        panelWindow = nil

        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != NSRunningApplication.current.processIdentifier {
            previousFrontmostAppPID = pid
        } else {
            previousFrontmostAppPID = nil
        }

        // 截图翻译只支持少量源语言选项（英语/俄语/西语），不提供自动检测。
        // 如果用户在主界面设置了其它源语言，这里默认回退到英语。
        let allowed: Set<String> = ["en", "ru", "es"]
        let source = allowed.contains(settings.sourceLanguageCode) ? settings.sourceLanguageCode : "en"

        let session = ScreenshotOCRSession(
            sourceLanguageCode: source,
            targetLanguageCode: settings.targetLanguageCode
        )
        session.frozenBackgrounds = frozenBackgrounds
        self.session = session

        let window = ScreenshotSelectionWindow(
            session: session,
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelAll()
                }
            },
            onSelectionConfirmed: { [weak self] _ in
                Task { @MainActor in
                    await self?.captureSelectionIfPossible(settings: settings, log: log, toast: toast)
                }
            },
            onTranslateTapped: { [weak self] in
                Task { @MainActor in
                    await self?.runOCRAndTranslateIfPossible(settings: settings, log: log, toast: toast)
                }
            },
            onExtractTapped: { [weak self] in
                Task { @MainActor in
                    await self?.extractOCRToPasteboardIfPossible(settings: settings, log: log, toast: toast)
                }
            },
            onPinTapped: { [weak self] in
                Task { @MainActor in
                    await self?.pinSelectionIfPossible(settings: settings, log: log, toast: toast)
                }
            },
            onFinishTapped: { [weak self] in
                Task { @MainActor in
                    await self?.finishCaptureToPasteboardIfPossible(settings: settings, log: log)
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    self?.cancelAll()
                }
            }
        )

        selectionWindow = window

        // 只展示选区层，不主动拉起主窗口。
        window.orderFrontRegardless()

        // 让窗口先成为 key，避免出现“第一次点击只是激活窗口、第二次才开始框选”的体验。
        window.makeKey()
        if let cv = window.contentView {
            window.makeFirstResponder(cv)
        }

        // Esc 即使在其它应用前台也可以退出截图翻译。
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if !self.isRunning { return }
            if event.keyCode == 53 { // ESC
                Task { @MainActor in
                    self.cancelAll()
                }
            }
        }
    }

    private func presentOverlay(text: String, rect: CGRect) {
        overlayWindow?.close()
        overlayWindow = nil

        let window = TranslationOverlayWindow(rect: rect, text: text)
        overlayWindow = window
        window.orderFrontRegardless()
    }

    private func captureSelectionIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        guard let selectionWindow else { return }

        let rectInScreen = selectionWindow.selectionRectInScreen().integral
        if rectInScreen.width < 8 || rectInScreen.height < 8 {
            return
        }

        // 框选完成后仅截图缓存，不做 OCR。
        session.stage = .selected
        session.ocrText = ""
        session.translatedText = ""
        session.ocrLines = []
        session.translatedLines = []
        session.capturedImage = nil
        session.didExtractTextToPasteboard = false
        session.showCompare = false

        do {
            session.capturedImage = try await captureImageExcludingOverlay(rect: rectInScreen, selectionWindow: selectionWindow)
        } catch {
            session.stage = .failed(error.localizedDescription)
            toast.show(error.localizedDescription, style: .error)
        }
    }

    private func runOCRAndTranslateIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        guard let selectionWindow else { return }

        if (session.stage == .ocrReady || session.stage == .translated),
           !session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await runTranslateIfPossible(settings: settings, log: log, toast: toast)
            return
        }

        // 没有缓存截图时兜底再截一次（例如某些异常状态）。
        if session.capturedImage == nil {
            let rectInScreen = selectionWindow.selectionRectInScreen().integral
            if rectInScreen.width >= 8, rectInScreen.height >= 8 {
                do {
                    session.capturedImage = try await captureImageExcludingOverlay(rect: rectInScreen, selectionWindow: selectionWindow)
                } catch {
                    session.stage = .failed(error.localizedDescription)
                    toast.show(error.localizedDescription, style: .error)
                    return
                }
            }
        }

        guard let image = session.capturedImage else { return }

        // 先 OCR
        session.stage = .ocrRunning
        let lines = await VisionOCRService.recognizeLines(from: image, preferredLanguageCode: session.sourceLanguageCode)
        session.ocrLines = lines
        session.ocrText = lines.map { $0.text }.joined(separator: "\n")

        if session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.stage = .failed("未识别到文字")
            toast.show("未识别到文字", style: .warning)
            return
        }

        session.stage = .ocrReady

        // 再翻译
        await runTranslateIfPossible(settings: settings, log: log, toast: toast)
    }

    private func extractOCRToPasteboardIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        guard let selectionWindow else { return }

        // 已经有 OCR 文本就直接复制，不重复跑 OCR。
        let existing = session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(existing, forType: .string)
            session.didExtractTextToPasteboard = true
            session.showHUD("已提取原文并复制到剪贴板", style: .success)
            return
        }

        // 没有缓存截图时兜底再截一次。
        if session.capturedImage == nil {
            let rectInScreen = selectionWindow.selectionRectInScreen().integral
            if rectInScreen.width >= 8, rectInScreen.height >= 8 {
                do {
                    session.capturedImage = try await captureImageExcludingOverlay(rect: rectInScreen, selectionWindow: selectionWindow)
                } catch {
                    session.showHUD(error.localizedDescription, style: .error)
                    return
                }
            }
        }
        guard let image = session.capturedImage else { return }

        session.stage = .ocrRunning
        let lines = await VisionOCRService.recognizeLines(from: image, preferredLanguageCode: session.sourceLanguageCode)
        session.ocrLines = lines
        session.ocrText = lines.map { $0.text }.joined(separator: "\n")
        let text = session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            session.stage = .failed("未识别到文字")
            session.showHUD("未识别到文字", style: .warning)
            return
        }

        session.stage = .ocrReady

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        session.didExtractTextToPasteboard = true
        session.showHUD("已提取原文并复制到剪贴板", style: .success)
    }

    private func pinSelectionIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        guard let selectionWindow else { return }

        if session.capturedImage == nil {
            let rectInScreen = selectionWindow.selectionRectInScreen().integral
            if rectInScreen.width >= 8, rectInScreen.height >= 8 {
                do {
                    session.capturedImage = try await captureImageExcludingOverlay(rect: rectInScreen, selectionWindow: selectionWindow)
                } catch {
                    toast.show(error.localizedDescription, style: .error)
                    return
                }
            }
        }
        guard let image = session.capturedImage else { return }

        let rectInScreen = selectionWindow.selectionRectInScreen().integral
        let maxW: CGFloat = 520
        let maxH: CGFloat = 360
        let w = image.size.width
        let h = image.size.height
        let scale = min(1.0, min(maxW / max(1, w), maxH / max(1, h)))
        let initialSize = CGSize(width: max(160, w * scale), height: max(120, h * scale))
        let initialRect = CGRect(
            x: rectInScreen.minX,
            y: rectInScreen.minY,
            width: initialSize.width,
            height: initialSize.height
        )

        var windowToRemove: PinnedScreenshotWindow?
        let pinned = PinnedScreenshotWindow(
            image: image,
            initialRect: initialRect,
            onRequestClose: { [weak self] in
                guard let self else { return }
                if let w = windowToRemove {
                    self.pinnedWindows.removeAll(where: { $0 === w })
                }
            },
            onRequestCloseAll: { [weak self] in
                self?.closeAllPinnedWindows()
            }
        )
        windowToRemove = pinned
        pinnedWindows.append(pinned)
        pinned.orderFrontRegardless()
        pinned.makeKey()
        session.showHUD("已钉到屏幕", style: .success)

        // 钉图后退出截图翻译，但保留钉图窗口。
        try? await Task.sleep(nanoseconds: 420_000_000)
        cancelAll()
    }

    private func closeAllPinnedWindows() {
        let windows = pinnedWindows
        pinnedWindows.removeAll()
        windows.forEach { $0.close() }
    }

    private func finishCaptureToPasteboardIfPossible(settings: AppSettings, log: LogStore) async {
        guard let session else { return }
        guard let selectionWindow else { return }

        // 如果用户刚刚执行过“提取原文”，则“完成”不应再用图片覆盖剪贴板。
        if session.didExtractTextToPasteboard {
            session.showHUD("已提取原文：完成将不会覆盖剪贴板", style: .info)
            return
        }

        // 确保有截图。
        if session.capturedImage == nil {
            let rectInScreen = selectionWindow.selectionRectInScreen().integral
            if rectInScreen.width >= 8, rectInScreen.height >= 8 {
                do {
                    session.capturedImage = try await captureImageExcludingOverlay(rect: rectInScreen, selectionWindow: selectionWindow)
                } catch {
                    session.showHUD(error.localizedDescription, style: .error)
                    return
                }
            }
        }

        guard let image = session.capturedImage else { return }

        // 用 PNG 数据写入剪贴板，保证“原汁原味”的像素输出（避免某些情况下写 NSImage 导致边缘异常）。
        if let data = pngData(from: image) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            session.showHUD("截图已保存到剪贴板", style: .success)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            session.showHUD("截图已保存到剪贴板", style: .success)
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    private func captureImageExcludingOverlay(rect: CGRect, selectionWindow: ScreenshotSelectionWindow) async throws -> NSImage {
        let prevAlpha = selectionWindow.alphaValue
        let prevIgnoresMouse = selectionWindow.ignoresMouseEvents

        selectionWindow.alphaValue = 0
        selectionWindow.ignoresMouseEvents = true
        defer {
            selectionWindow.alphaValue = prevAlpha
            selectionWindow.ignoresMouseEvents = prevIgnoresMouse
        }

        // 给系统一点时间让窗口真正隐藏，否则仍可能被捕捉到边框。
        try? await Task.sleep(nanoseconds: 90_000_000)
        return try await ScreenRegionCapture.capture(rect: rect)
    }

    private func captureFrozenBackgrounds(log: LogStore) async -> [ScreenshotOCRSession.FrozenBackground] {
        let virtualFrame = ScreenshotSelectionWindow.fullVirtualScreenFrame()
        if virtualFrame == .zero { return [] }

        var items: [ScreenshotOCRSession.FrozenBackground] = []
        items.reserveCapacity(NSScreen.screens.count)

        for screen in NSScreen.screens {
            let rectInScreen = screen.frame
            do {
                let image = try await ScreenRegionCapture.capture(rect: rectInScreen)
                // 转换到 selectionWindow content 坐标（左下原点）。
                let rectInContent = CGRect(
                    x: rectInScreen.minX - virtualFrame.minX,
                    y: rectInScreen.minY - virtualFrame.minY,
                    width: rectInScreen.width,
                    height: rectInScreen.height
                )
                items.append(.init(image: image, rect: rectInContent))
            } catch {
                log.warn("冻结背景截图失败：\(error.localizedDescription)，将使用实时背景")
                return []
            }
        }

        return items
    }

    private func detectLanguageCode(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let lang = recognizer.dominantLanguage else { return nil }

        // 兜底：俄语 OCR 有时会把西里尔字母识别成拉丁字母/数字，导致系统误判成葡语/英语等。
        // 这里用一个轻量规则：如果文本明显像俄语“伪拉丁”，则强制当作俄语。
        if looksLikeRussianOCRArtifacts(trimmed) {
            return "ru"
        }

        switch lang {
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        case .english:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .russian:
            return "ru"
        case .vietnamese:
            return "vi"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .spanish:
            return "es"
        case .portuguese:
            return "pt"
        case .italian:
            return "it"
        default:
            return nil
        }
    }

    private func looksLikeRussianOCRArtifacts(_ text: String) -> Bool {
        let t = text
        if t.range(of: "\\bnpnBeT\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if t.range(of: "\\b3TO\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }

        // 统计一段样本里“像西里尔被错成拉丁”的字符占比。
        let sample = String(t.prefix(220))
        let mappable: Set<Character> = [
            "A", "B", "C", "E", "H", "K", "M", "O", "P", "T", "X", "Y",
            "N", "U", "L", "I",
            "a", "c", "e", "o", "p", "x", "y", "k", "m", "t",
            "n", "u", "l", "i",
            "3", "0"
        ]
        let lettersDigits = sample.filter {
            guard let u = $0.unicodeScalars.first else { return false }
            return CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u)
        }
        if lettersDigits.count < 24 { return false }

        let hits = lettersDigits.filter { mappable.contains($0) }.count
        return Double(hits) / Double(lettersDigits.count) >= 0.62
    }

    private func runTranslateIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        let sourceLines = session.ocrLines
        if sourceLines.isEmpty {
            let text = session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
        }

        session.stage = .translating

        switch settings.engineType {
        case .google:
            log.info("截图翻译引擎：Google")
        case .openAICompatible:
            log.info("截图翻译引擎：OpenAI 通用接口")
        }

        // OpenAI：优先批量翻译，减少逐行导致的上下文缺失与随机错误。
        // 通过 [[DAZUO_NL]] 保持行分隔，翻译后再按分隔符切回每行。
        if !sourceLines.isEmpty, settings.engineType == .openAICompatible {
            // 大段内容一次性请求更容易不稳定/超限，这里做分块：每块多行一次请求。
            // 这样既能保留上下文，又能提高成功率。
            let maxLinesPerChunk = 14
            let maxCharsPerChunk = 2200

            var translatedAll: [VisionOCRService.OCRLine] = []
            translatedAll.reserveCapacity(sourceLines.count)

            var startIndex = 0
            while startIndex < sourceLines.count {
                var endIndex = startIndex
                var chars = 0

                while endIndex < sourceLines.count {
                    let next = sourceLines[endIndex].text
                    let add = next.count + 14
                    if endIndex > startIndex {
                        if (endIndex - startIndex) >= maxLinesPerChunk { break }
                        if (chars + add) > maxCharsPerChunk { break }
                    }
                    chars += add
                    endIndex += 1
                }

                let chunk = Array(sourceLines[startIndex ..< endIndex])
                let joined = chunk.map { $0.text }.joined(separator: " [[DAZUO_NL]] ")

                let result = await translate(
                    text: joined,
                    sourceLanguageCode: session.sourceLanguageCode,
                    targetLanguageCode: session.targetLanguageCode,
                    settings: settings,
                    log: log,
                    toast: toast,
                    onPhaseChange: nil
                )

                func fallbackTranslateChunkLineByLine() async -> Bool {
                    for line in chunk {
                        let r = await translate(
                            text: line.text,
                            sourceLanguageCode: session.sourceLanguageCode,
                            targetLanguageCode: session.targetLanguageCode,
                            settings: settings,
                            log: log,
                            toast: toast,
                            onPhaseChange: nil
                        )

                        switch r {
                        case .success(let t):
                            translatedAll.append(.init(text: t, boundingBox: line.boundingBox))
                        case .failure(let error):
                            session.stage = .failed(error.localizedDescription)
                            toast.show(error.localizedDescription, style: .error)
                            return false
                        }
                    }
                    return true
                }

                switch result {
                case .success(let translatedText):
                    let rawParts = translatedText.components(separatedBy: "[[DAZUO_NL]]")
                    let parts = rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

                    if parts.count >= chunk.count {
                        for (src, t) in zip(chunk, parts.prefix(chunk.count)) {
                            translatedAll.append(.init(text: t, boundingBox: src.boundingBox))
                        }
                    } else {
                        log.warn("OpenAI 批量翻译分行失败：expected=\(chunk.count), got=\(parts.count)，该块降级逐行")
                        let ok = await fallbackTranslateChunkLineByLine()
                        if !ok { return }
                    }

                case .failure(let error):
                    log.warn("OpenAI 批量翻译失败：\(error.localizedDescription)，该块降级逐行")
                    let ok = await fallbackTranslateChunkLineByLine()
                    if !ok { return }
                }

                startIndex = endIndex
            }

            session.translatedLines = translatedAll
            session.translatedText = translatedAll.map { $0.text }.joined(separator: "\n")
            session.stage = .translated
            return
        }

        // 默认：逐条翻译以保持“你在翻译哪一条”的对应关系。
        if !sourceLines.isEmpty {
            var translated: [VisionOCRService.OCRLine] = []
            translated.reserveCapacity(sourceLines.count)

            for line in sourceLines {
                let result = await translate(
                    text: line.text,
                    sourceLanguageCode: session.sourceLanguageCode,
                    targetLanguageCode: session.targetLanguageCode,
                    settings: settings,
                    log: log,
                    toast: toast,
                    onPhaseChange: nil
                )

                switch result {
                case .success(let t):
                    translated.append(.init(text: t, boundingBox: line.boundingBox))
                case .failure(let error):
                    session.stage = .failed(error.localizedDescription)
                    toast.show(error.localizedDescription, style: .error)
                    return
                }
            }

            session.translatedLines = translated
            session.translatedText = translated.map { $0.text }.joined(separator: "\n")
            session.stage = .translated
            return
        }

        // fallback：没有行数据时仍然整段翻译
        let text = session.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await translate(
            text: text,
            sourceLanguageCode: session.sourceLanguageCode,
            targetLanguageCode: session.targetLanguageCode,
            settings: settings,
            log: log,
            toast: toast,
            onPhaseChange: nil
        )

        switch result {
        case .success(let translated):
            session.translatedText = translated
            session.translatedLines = []
            session.stage = .translated
        case .failure(let error):
            session.stage = .failed(error.localizedDescription)
            toast.show(error.localizedDescription, style: .error)
        }
    }

    private func finishOverlayIfPossible(toast: ToastCenter) {
        guard let session else { return }
        guard let selectionWindow else { return }

        if session.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toast.show("还没有译文，无法完成", style: .warning)
            return
        }

        let rectInScreen = selectionWindow.selectionRectInScreen().integral
        if !session.translatedLines.isEmpty {
            let window = TranslationOverlayWindow(rect: rectInScreen, text: session.translatedText, lines: session.translatedLines)
            overlayWindow = window
            window.orderFrontRegardless()
        } else {
            presentOverlay(text: session.translatedText, rect: rectInScreen)
        }
        cancelAll()
    }

    private func translate(
        text: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        settings: AppSettings,
        log: LogStore,
        toast: ToastCenter,
        onPhaseChange: ((String) -> Void)?
    ) async -> Result<String, Error> {
        let engine: TranslationEngine
        switch settings.engineType {
        case .google:
            engine = GoogleTranslateEngine()
        case .openAICompatible:
            let key: String?
            do {
                key = try KeychainStore.getString(for: "openAIAPIKey")
            } catch {
                return .failure(error)
            }
            engine = OpenAICompatibleEngine(
                baseURL: settings.openAIBaseURL,
                apiKey: key,
                model: settings.openAIModel,
                endpointMode: settings.openAIEndpointMode,
                onPhaseChange: onPhaseChange
            )
        }

        do {
            let result = try await engine.translate(
                text: text,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode
            )
            return .success(result.translatedText)
        } catch {
            if let rl = error as? OpenAICompatibleEngine.RateLimitError {
                let base = "请求过多（\(rl.apiCode)）：\(rl.apiMessage)"
                toast.show(base, style: .warning, duration: 1.0)
                toast.show("准备重试中（2秒）", style: .info, duration: 1.0)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                toast.show("准备重试中（1秒）", style: .info, duration: 1.0)
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                do {
                    let retry = try await engine.translate(
                        text: text,
                        sourceLanguageCode: sourceLanguageCode,
                        targetLanguageCode: targetLanguageCode
                    )
                    return .success(retry.translatedText)
                } catch {
                    log.error("截图翻译重试失败：\(error.localizedDescription)")
                    return .failure(error)
                }
            }

            log.error("截图翻译失败：\(error.localizedDescription)")
            return .failure(error)
        }
    }
}
