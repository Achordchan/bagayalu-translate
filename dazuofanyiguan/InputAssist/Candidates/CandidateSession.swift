import ApplicationServices
import Foundation

/// 候选浮层创建时冻结下来的一切（PRD §45）。
///
/// Commit 前拿它和当前状态比对；对不上就取消替换并关闭浮层。
struct CandidateSession {
    let sessionID: UUID
    let appBundleIdentifier: String?
    let element: AXUIElement
    let sourceText: String
    let sourceRange: InputAssistTextRange?
    let elementValueAtCapture: String?
    let context: String
    let capability: InputAssistSurfaceCapability
    let role: String?
    let allowsEditorPaste: Bool
    let anchorRect: CGRect
    /// 取词那一刻的选区 / 光标位置，替换前要比对（见 InputAssistCapture 的注释）。
    let selectedRangeAtCapture: InputAssistTextRange?
    let detectedSourceLanguageCode: String?
    let createdAt: Date

    /// 这个会话是不是就为**这一段**选区开的。
    ///
    /// 用来防止两条延迟路径为同一段选区各开一次：自动显示等 180ms、
    /// 快捷键的 Chromium 重试等 200ms，谁先到都可能已经开好了浮层。
    func matchesSelection(of capture: InputAssistCapture) -> Bool {
        CFEqual(element, capture.element)
            && sourceText == capture.sourceText
            && sourceRange == capture.sourceRange
    }

    init(
        sessionID: UUID = UUID(),
        appBundleIdentifier: String?,
        capture: InputAssistCapture,
        detectedSourceLanguageCode: String?,
        createdAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.appBundleIdentifier = appBundleIdentifier
        self.element = capture.element
        self.sourceText = capture.sourceText
        self.sourceRange = capture.sourceRange
        self.elementValueAtCapture = capture.elementValue
        self.context = capture.context
        self.capability = capture.capability
        self.role = capture.role
        self.allowsEditorPaste = capture.allowsEditorPaste
        self.anchorRect = capture.anchorRect
        self.selectedRangeAtCapture = capture.selectedRangeAtCapture
        self.detectedSourceLanguageCode = detectedSourceLanguageCode
        self.createdAt = createdAt
    }
}
