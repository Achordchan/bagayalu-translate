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
    let anchorRect: CGRect
    let detectedSourceLanguageCode: String?
    let createdAt: Date

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
        self.anchorRect = capture.anchorRect
        self.detectedSourceLanguageCode = detectedSourceLanguageCode
        self.createdAt = createdAt
    }
}
