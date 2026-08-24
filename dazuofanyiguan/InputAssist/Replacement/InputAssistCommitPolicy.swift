import Foundation

enum InputAssistCommitMode: Equatable {
    case axReplace
    case editorPaste
    case copy
}

/// 候选提交时的唯一能力分级。
enum InputAssistCommitPolicy {
    static func mode(
        capability: InputAssistSurfaceCapability,
        allowsEditorPaste: Bool,
        hasSourceRange: Bool,
        hasElementValue: Bool
    ) -> InputAssistCommitMode {
        if capability == .axDirect, hasSourceRange, hasElementValue {
            return .axReplace
        }
        if capability != .unavailable, allowsEditorPaste {
            return .editorPaste
        }
        return .copy
    }

    static func isEditableRole(_ role: String?) -> Bool {
        switch role {
        case "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField":
            return true
        default:
            return false
        }
    }
}
