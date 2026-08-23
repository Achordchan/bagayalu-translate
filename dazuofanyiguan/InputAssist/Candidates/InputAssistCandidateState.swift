import Foundation

/// 一行候选的来源，用于 ⚡ 缓存标识与 ⌥ 调试态（PRD §22 / §23）。
enum CandidateResultSource: String, Equatable {
    case network
    case cache
}

enum CandidateRowState: Equatable {
    /// 骨架态。浮层第一次出现时所有行都是它（PRD §12.1）。
    case loading
    case translated(text: String, source: CandidateResultSource, latencyMilliseconds: Int)
    /// 单条失败不拖垮整个浮层，支持点击重试（PRD §19）。
    case failed(message: String)
    /// Apple 本地翻译缺语言包（PRD §20）。
    case languagePackRequired
}

struct CandidateRow: Equatable, Identifiable {
    let languageCode: String
    var state: CandidateRowState

    var id: String { languageCode }

    /// 语言的紧凑标识，例如 EN / ES / ZH-CN（PRD §11.2：不用国旗）。
    var displayCode: String {
        languageCode.uppercased()
    }

    var translatedText: String? {
        guard case .translated(let text, _, _) = state else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    var isCommittable: Bool { translatedText != nil }
}

/// 候选列表的纯状态机：只管行内容与高亮位置，不碰窗口、不碰翻译。
struct CandidateListState: Equatable {
    private(set) var rows: [CandidateRow]
    /// PRD §10.3：默认永远高亮第一项，且不因为使用习惯自动改变。
    private(set) var selectedIndex: Int

    init(languageCodes: [String]) {
        rows = languageCodes.map { CandidateRow(languageCode: $0, state: .loading) }
        selectedIndex = 0
    }

    var count: Int { rows.count }
    var isEmpty: Bool { rows.isEmpty }

    var selectedRow: CandidateRow? {
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    var committableIndices: Set<Int> {
        Set(rows.indices.filter { rows[$0].isCommittable })
    }

    var isFullySettled: Bool {
        rows.allSatisfy { $0.state != .loading }
    }

    /// ↑ / ↓ 到头就停，不循环。
    ///
    /// PRD §2.2「可预测」优先：连按 ↓ 会停在最后一项，而不是绕回第一项
    /// 让用户以为自己按漏了。
    @discardableResult
    mutating func moveSelection(by delta: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        let target = min(max(selectedIndex + delta, 0), rows.count - 1)
        guard target != selectedIndex else { return false }
        selectedIndex = target
        return true
    }

    @discardableResult
    mutating func select(index: Int) -> Bool {
        guard rows.indices.contains(index), index != selectedIndex else { return false }
        selectedIndex = index
        return true
    }

    @discardableResult
    mutating func update(languageCode: String, state: CandidateRowState) -> Bool {
        guard let index = rows.firstIndex(where: { $0.languageCode == languageCode }) else {
            return false
        }
        guard rows[index].state != state else { return false }
        rows[index].state = state
        return true
    }

    func index(of languageCode: String) -> Int? {
        rows.firstIndex(where: { $0.languageCode == languageCode })
    }
}
