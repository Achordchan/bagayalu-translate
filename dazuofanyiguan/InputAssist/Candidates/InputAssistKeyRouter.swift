import Foundation

/// 一次按键的最小描述。刻意不依赖 CGEvent / NSEvent，这样按键规则可以直接单测。
struct InputAssistKeyEvent: Equatable {
    let keyCode: Int
    let hasCommand: Bool
    let hasOption: Bool
    let hasControl: Bool
    let hasShift: Bool

    init(
        keyCode: Int,
        hasCommand: Bool = false,
        hasOption: Bool = false,
        hasControl: Bool = false,
        hasShift: Bool = false
    ) {
        self.keyCode = keyCode
        self.hasCommand = hasCommand
        self.hasOption = hasOption
        self.hasControl = hasControl
        self.hasShift = hasShift
    }
}

enum InputAssistKeyAction: Equatable {
    case moveUp
    case moveDown
    /// 用当前高亮译文替换原文。
    case commit
    /// 直接选中第 n 项并替换（⌘1–⌘6）。
    case commitIndex(Int)
    case copySelection
    case dismiss
    /// 关掉浮层，但这次按键仍然要送进原 App（普通输入 / Space）。
    case dismissPassingEventThrough
}

struct InputAssistKeyDecision: Equatable {
    let action: InputAssistKeyAction
    /// true = 吞掉事件，不投递给原 App。
    let swallowsEvent: Bool
}

/// 候选浮层可见期间的按键裁决（PRD §14 / §15）。
///
/// 返回 nil 表示「这个键与我们无关」：原样放行，浮层保持不变。
enum InputAssistKeyRouter {
    // HIToolbox virtual key codes。注意 5 和 6 不是连号，这是 ANSI 键盘的历史遗留。
    static let upArrow = 126
    static let downArrow = 125
    static let leftArrow = 123
    static let rightArrow = 124
    static let returnKey = 36
    static let keypadEnter = 76
    static let escape = 53
    static let space = 49
    static let tab = 48
    static let cKey = 8
    static let digitKeyCodes = [18, 19, 20, 21, 23, 22]

    static func decide(
        for event: InputAssistKeyEvent,
        candidateCount: Int,
        selectedIndex: Int,
        committableIndices: Set<Int>
    ) -> InputAssistKeyDecision? {
        if event.hasCommand {
            return decideCommandCombination(
                event,
                candidateCount: candidateCount,
                selectedIndex: selectedIndex,
                committableIndices: committableIndices
            )
        }

        // ⌃ 组合基本都是文本编辑光标操作（⌃A 行首、⌃E 行尾…），
        // 一律视为光标移动：关浮层并放行（PRD §15）。
        if event.hasControl {
            return InputAssistKeyDecision(
                action: .dismissPassingEventThrough,
                swallowsEvent: false
            )
        }

        switch event.keyCode {
        case escape:
            return InputAssistKeyDecision(action: .dismiss, swallowsEvent: true)

        case upArrow:
            return InputAssistKeyDecision(action: .moveUp, swallowsEvent: true)

        case downArrow:
            return InputAssistKeyDecision(action: .moveDown, swallowsEvent: true)

        case returnKey, keypadEnter:
            // 还没有任何译文可用时不能把 Enter 吞掉：
            // 在聊天窗口里那等于让用户的消息发不出去，比不翻译更糟。
            guard committableIndices.contains(selectedIndex) else {
                return InputAssistKeyDecision(
                    action: .dismissPassingEventThrough,
                    swallowsEvent: false
                )
            }
            return InputAssistKeyDecision(action: .commit, swallowsEvent: true)

        case leftArrow, rightArrow:
            // 光标移动 → 之前记录的 source range 立刻作废（PRD §15 / §44）。
            return InputAssistKeyDecision(
                action: .dismissPassingEventThrough,
                swallowsEvent: false
            )

        default:
            // Space 与普通字符都算「用户继续输入」：关浮层，键照送（PRD §14 表格）。
            return InputAssistKeyDecision(
                action: .dismissPassingEventThrough,
                swallowsEvent: false
            )
        }
    }

    /// ⌥ 按住时临时显示调试信息（PRD §23）。
    ///
    /// 只认单独按住 Option：和别的修饰键一起按通常是某个真实快捷键，不该翻出调试态。
    static func showsDebugOverlay(
        hasOption: Bool,
        hasCommand: Bool,
        hasControl: Bool,
        hasShift: Bool
    ) -> Bool {
        hasOption && !hasCommand && !hasControl && !hasShift
    }

    private static func decideCommandCombination(
        _ event: InputAssistKeyEvent,
        candidateCount: Int,
        selectedIndex: Int,
        committableIndices: Set<Int>
    ) -> InputAssistKeyDecision? {
        // ⌘ 必须是**唯一**的修饰键。
        //
        // 否则 ⌘⇧3 / ⌘⇧4 / ⌘⇧5 这些系统截图快捷键会被当成 ⌘3 / ⌘4 / ⌘5 吞掉，
        // 用户想截个图，结果截不成、还顺手把对应语言的译文替换了进去。
        let hasOnlyCommand = !event.hasShift && !event.hasOption && !event.hasControl

        if hasOnlyCommand, let digitIndex = digitKeyCodes.firstIndex(of: event.keyCode) {
            // ⌘4 但只有 3 个候选：这多半是原 App 自己的快捷键，别抢也别关浮层。
            guard digitIndex < candidateCount else { return nil }
            guard committableIndices.contains(digitIndex) else { return nil }
            return InputAssistKeyDecision(
                action: .commitIndex(digitIndex),
                swallowsEvent: true
            )
        }

        if hasOnlyCommand, event.keyCode == cKey {
            guard committableIndices.contains(selectedIndex) else { return nil }
            return InputAssistKeyDecision(action: .copySelection, swallowsEvent: true)
        }

        // 其它 ⌘ 组合（⌘Z / ⌘A / ⌘V…）都会改动文本或光标，
        // 浮层记录的快照随即失效：关掉，但绝不拦截用户真正的快捷键。
        return InputAssistKeyDecision(
            action: .dismissPassingEventThrough,
            swallowsEvent: false
        )
    }
}
