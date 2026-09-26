import AppKit
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenshotOCRCoordinator: ObservableObject {
    @Published private(set) var isRunning: Bool = false

    private let appleTranslationCoordinator: AppleTranslationCoordinator

    private var session: ScreenshotOCRSession?
    private var selectionWindow: ScreenshotSelectionWindow?

    private var pinnedWindows: [PinnedScreenshotWindow] = []

    private var globalKeyMonitor: Any?

    private var previousFrontmostAppPID: pid_t?

    /// 回贴图在后台画，同一时间只画一张；画的时候又来的请求合并成画完后的一次。
    private var overlayRenderTask: Task<Void, Never>?
    private var overlayNeedsRender = false
    /// 同一批识别结果多次重画时复用量过的样式；重新识别时换一个。
    private var overlayStyleCache = ScreenshotTranslationRenderer.StyleCache()

    init(appleTranslationCoordinator: AppleTranslationCoordinator) {
        self.appleTranslationCoordinator = appleTranslationCoordinator
    }

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
        appleTranslationCoordinator.cancel()
        session = nil
        selectionWindow?.close()
        selectionWindow = nil

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
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != NSRunningApplication.current.processIdentifier {
            previousFrontmostAppPID = pid
        } else {
            previousFrontmostAppPID = nil
        }

        // 源语言跟随主界面设置（默认自动检测）。主界面选的语言 Vision 认不出时退回自动检测：
        // 以前是退回英语，中日韩文字会被当成英文去认，结果整段乱码。
        let selectable = Set(VisionOCRService.selectableSourceLanguages.map(\.code))
        let source = selectable.contains(settings.sourceLanguageCode)
            ? settings.sourceLanguageCode
            : LanguagePreset.auto.code

        let session = ScreenshotOCRSession(
            sourceLanguageCode: source,
            targetLanguageCode: settings.targetLanguageCode
        )
        session.frozenBackgrounds = frozenBackgrounds
        self.session = session

        let window = ScreenshotSelectionWindow(
            session: session,
            appleTranslationCoordinator: appleTranslationCoordinator,
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
                    // 按钮这时是灰的；真点进来了也别往下走，什么都没复制就退出，用户会以为复制好了。
                    guard self?.session?.canExport == true else { return }
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


    private func captureSelectionIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        guard let selectionWindow else { return }

        let rectInScreen = selectionWindow.selectionRectInScreen().integral
        if rectInScreen.width < 8 || rectInScreen.height < 8 {
            return
        }

        // 框选完成后仅截图缓存，不做 OCR。
        session.resetResults()
        session.stage = .selected
        let generation = session.generation

        do {
            let image = try await captureImageExcludingOverlay(rect: rectInScreen, selectionWindow: selectionWindow)
            guard isCurrent(session, generation) else { return }
            session.capturedImage = image
        } catch {
            guard isCurrent(session, generation) else { return }
            session.stage = .failed(error.localizedDescription)
            toast.show(error.localizedDescription, style: .error)
        }
    }

    /// 异步步骤回来时，选区和源语言还是发起时那一份吗。
    private func isCurrent(_ session: ScreenshotOCRSession, _ generation: Int) -> Bool {
        self.session === session && session.generation == generation
    }

    /// 识别文字并写进 session。没认出字、或结果已经过期时返回 false。
    private func recognizeText(in image: NSImage, session: ScreenshotOCRSession) async -> Bool {
        let generation = session.generation
        session.stage = .ocrRunning
        let blocks = await VisionOCRService.recognizeBlocks(from: image, languageCode: session.sourceLanguageCode)
        guard isCurrent(session, generation) else { return false }

        session.ocrBlocks = blocks
        session.translations = [:]
        session.translatedImage = nil
        session.overlayUnavailable = false
        overlayStyleCache = ScreenshotTranslationRenderer.StyleCache()
        session.translatedText = ""
        session.ocrText = blocks.map(\.text).joined(separator: "\n")
        if blocks.isEmpty {
            session.stage = .failed("未识别到文字")
            return false
        }
        session.stage = .ocrReady
        return true
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
        let generation = session.generation
        guard await recognizeText(in: image, session: session) else {
            if isCurrent(session, generation) {
                toast.show("未识别到文字", style: .warning)
            }
            return
        }

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

        let generation = session.generation
        guard await recognizeText(in: image, session: session) else {
            if isCurrent(session, generation) {
                session.showHUD("未识别到文字", style: .warning)
            }
            return
        }
        let text = session.ocrText

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        session.didExtractTextToPasteboard = true
        session.showHUD("已提取原文并复制到剪贴板", style: .success)
    }

    private func pinSelectionIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        guard let selectionWindow else { return }
        guard session.canExport else { return }

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
        // 翻完了钉的是贴了译文的图：钉图就是为了一边看译文一边做别的事。
        guard let export = session.imageForExport() else { return }
        let image = export.image

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
        if export.kind == .originalBecauseOverlayFailed {
            session.showHUD("译文图没画出来，钉的是原截图", style: .warning)
        } else {
            session.showHUD("已钉到屏幕", style: .success)
        }

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

        // 选区里显示的是哪张就复制哪张：翻完了是贴了译文的图。
        guard let export = session.imageForExport() else { return }
        let image = export.image

        // 用 PNG 数据写入剪贴板，保证“原汁原味”的像素输出（避免某些情况下写 NSImage 导致边缘异常）。
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = pngData(from: image) {
            pb.setData(data, forType: .png)
        } else {
            pb.writeObjects([image])
        }
        switch export.kind {
        case .original:
            session.showHUD("截图已复制到剪贴板", style: .success)
        case .translated:
            session.showHUD("译文截图已复制到剪贴板", style: .success)
        case .originalBecauseOverlayFailed:
            session.showHUD("译文图没画出来，复制的是原截图", style: .warning)
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

        // 所有屏幕共用同一次 SCShareableContent 查询，避免每块屏都重新枚举全系统窗口。
        let content: SCShareableContent
        do {
            content = try await ScreenRegionCapture.shareableContent()
        } catch {
            log.warn("冻结背景截图失败：\(error.localizedDescription)，将使用实时背景")
            return []
        }

        for screen in NSScreen.screens {
            let rectInScreen = screen.frame
            do {
                let image = try await ScreenRegionCapture.capture(
                    rect: rectInScreen,
                    content: content
                )
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

    private func runTranslateIfPossible(settings: AppSettings, log: LogStore, toast: ToastCenter) async {
        guard let session else { return }
        let blocks = session.ocrBlocks
        guard !blocks.isEmpty else { return }
        let generation = session.generation
        let targetLanguageCode = session.targetLanguageCode

        session.stage = .translating
        session.translations = [:]
        session.translatedImage = nil
        session.overlayUnavailable = false

        switch settings.engineType {
        case .apple:
            log.info("截图翻译引擎：Apple 本地翻译")
        case .google:
            log.info("截图翻译引擎：Google")
        case .microsoft:
            log.info("截图翻译引擎：微软翻译")
        case .openAICompatible:
            log.info("截图翻译引擎：OpenAI 通用接口")
        }

        // 按段翻译（折行已经拼回整段），每段各自判断源语言；已经是目标语言的段落原样保留。
        let sources = ScreenshotTranslationSourceResolver.resolve(
            blockTexts: blocks.map(\.text),
            sourceLanguageCode: session.sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
        var translations: [UUID: String] = [:]
        var jobs: [ScreenshotBlockTranslator.Job] = []
        for (block, source) in zip(blocks, sources) {
            if let source {
                jobs.append(.init(id: block.id, text: block.text, sourceLanguageCode: source))
            } else {
                translations[block.id] = block.text
            }
        }

        guard !jobs.isEmpty else {
            session.translations = translations
            session.translatedText = session.ocrText
            session.stage = .translated
            session.showHUD("选区里没有需要翻译成\(LanguagePreset.displayName(for: targetLanguageCode))的文字", style: .info)
            return
        }

        let translator = ScreenshotBlockTranslator(
            batchesRequests: settings.engineType != .apple,
            translate: { [weak self] text, sourceLanguageCode in
                guard let self else { return .failure(CancellationError()) }
                return await self.translate(
                    text: text,
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    settings: settings,
                    log: log,
                    toast: toast,
                    onPhaseChange: nil
                )
            },
            followUpSource: { translation in
                ScreenshotTranslationSourceResolver.variantConversionSource(for: translation, targetLanguageCode: targetLanguageCode)
            }
        )
        let skipped = translations
        guard let outcome = await translator.run(
            jobs,
            shouldContinue: { [weak self] in self?.isCurrent(session, generation) ?? false },
            onProgress: { [weak self] progress in
                session.translations = skipped.merging(progress) { _, new in new }
                self?.scheduleOverlayRender()
            }
        ) else { return }
        guard isCurrent(session, generation) else { return }

        if outcome.succeeded == 0, let error = outcome.failures.first {
            session.translations = [:]
            session.translatedImage = nil
            session.stage = .failed(error.localizedDescription)
            toast.show(error.localizedDescription, style: .error)
            return
        }

        translations.merge(outcome.translations) { _, new in new }
        session.translations = translations
        scheduleOverlayRender()
        session.translatedText = blocks.map { translations[$0.id] ?? $0.text }.joined(separator: "\n")
        session.stage = .translated
        if let warning = outcome.incompleteWarning(
            jobCount: jobs.count,
            targetName: LanguagePreset.displayName(for: targetLanguageCode)
        ) {
            session.showHUD(warning, style: .warning)
        }
    }

    /// 按当前的识别结果和译文重画回贴图。放在后台画；正在画的时候又来的请求合并成一次，画完再按最新的译文画。
    /// 画好的图对不上当前的选区（换了选区、换了源语言、重新识别了）就丢掉。
    /// 画的这段时间 `overlayRenderPending` 为 true，「钉到屏幕」「完成」是灰的，免得拿走上一批的图。
    private func scheduleOverlayRender() {
        overlayNeedsRender = true
        if let session, !session.overlayRenderPending {
            session.overlayRenderPending = true
        }
        guard overlayRenderTask == nil else { return }
        overlayRenderTask = Task { @MainActor [weak self] in
            while let self, self.overlayNeedsRender {
                self.overlayNeedsRender = false
                guard let session = self.session,
                      let image = session.capturedImage,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let generation = session.generation
                let pointSize = image.size
                let input = ScreenshotTranslationRenderer.Input(
                    image: cgImage,
                    pointSize: pointSize,
                    blocks: session.ocrBlocks,
                    translations: session.translations,
                    cache: self.overlayStyleCache
                )
                let rendered = await Task.detached(priority: .userInitiated) {
                    ScreenshotTranslationRenderer.render(input)
                }.value
                guard self.isCurrent(session, generation) else { continue }
                session.applyOverlayRender(rendered.map { NSImage(cgImage: $0, size: pointSize) })
            }
            self?.overlayRenderTask = nil
            // 没有要画的了。换过会话的话旧会话已经扔掉，清当前这个就够。
            self?.session?.overlayRenderPending = false
        }
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
        await ScreenshotTranslationService.translate(
            text: text,
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode,
            settings: settings,
            log: log,
            toast: toast,
            appleTranslationCoordinator: appleTranslationCoordinator,
            onPhaseChange: onPhaseChange
        )
    }

}
