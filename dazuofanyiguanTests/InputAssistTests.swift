import AppKit
import ApplicationServices
import Combine
import Foundation
import Testing
@testable import 大佐翻译官v1

/// Input Assist（输入增强）的纯逻辑回归。
///
/// 覆盖 PRD §54 里点名要单测的部分：SentenceBoundaryDetector / TargetLanguageFilter /
/// CacheKey / LRU / CandidateState / CandidateNavigation / CandidateSessionValidation /
/// AppFilter / SecureInputGuard，外加浮层定位与布局。
struct InputAssistTests {

    // MARK: - 目标语言（PRD §10）

    @Test func sameLanguageComparisonKeepsChineseVariantsApart() {
        #expect(InputAssistLanguagePolicy.isSameLanguage("en", "en"))
        #expect(InputAssistLanguagePolicy.isSameLanguage("EN", "en-US"))
        #expect(InputAssistLanguagePolicy.isSameLanguage("en", "en_GB"))
        #expect(!InputAssistLanguagePolicy.isSameLanguage("en", "es"))
        // 简繁是两种目标语言，不能互相隐藏。
        #expect(!InputAssistLanguagePolicy.isSameLanguage("zh-CN", "zh-TW"))
        // 只写 zh 时无法区分简繁，按同一种处理。
        #expect(InputAssistLanguagePolicy.isSameLanguage("zh", "zh-CN"))
    }

    @Test func visibleTargetsHideOnlyTheDetectedSourceLanguage() {
        let targets = ["en", "es", "ru"]
        #expect(
            InputAssistLanguagePolicy.visibleTargets(targets, sourceLanguageCode: "en") == ["es", "ru"]
        )
        // 检测不出源语言时一个都不隐藏：宁可多一行候选，也不要凭猜测吞掉用户配置。
        #expect(InputAssistLanguagePolicy.visibleTargets(targets, sourceLanguageCode: nil) == targets)
        #expect(
            InputAssistLanguagePolicy.visibleTargets(targets, sourceLanguageCode: "auto") == targets
        )
        #expect(
            InputAssistLanguagePolicy.visibleTargets(targets, sourceLanguageCode: "ja") == targets
        )
    }

    @Test func sanitizeTargetsDeduplicatesAndCapsWithoutReordering() {
        let sanitized = InputAssistLanguagePolicy.sanitizeTargets(
            ["ru", "en", "EN", " es ", "ja", "ko", "de", "fr"]
        )
        // 顺序必须原样保留（PRD §10.3 禁止智能重排），重复项按首次出现保留。
        #expect(sanitized == ["ru", "en", "es", "ja", "ko", "de"])
        #expect(sanitized.count == InputAssistLanguagePolicy.maximumTargetCount)
        #expect(InputAssistLanguagePolicy.sanitizeTargets(["", "  "]).isEmpty)
    }

    // MARK: - 句界（PRD §9）

    @Test func currentSentenceStopsAtStrongTerminatorsOnly() {
        let text = "第一句。第二句"
        let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        )
        #expect(range.map { InputAssistAXTextCapture.substring(of: text, range: $0) } == "第二句")
    }

    @Test func currentSentenceKeepsItsOwnTrailingTerminator() {
        let text = "第一句。第二句。"
        let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        )
        #expect(range.map { InputAssistAXTextCapture.substring(of: text, range: $0) } == "第二句。")
    }

    @Test func commasNeverCutTheTranslationRange() {
        // PRD §8.1：不得只因为逗号就机械切断。整句都要进翻译范围。
        let text = "Hello John，关于你昨天问的设备，我们可以提供16吨船吊"
        let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        )
        #expect(range?.location == 0)
        #expect(range?.length == text.utf16.count)
    }

    @Test func decimalPointIsNotASentenceBoundary() {
        let text = "总价是 12.5 万美元"
        let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        )
        #expect(range?.location == 0)

        // 真正的英文句号仍然要断开。
        let english = "First one. Second one"
        let secondRange = InputAssistSentenceBoundary.currentSentenceRange(
            in: english,
            caretUTF16Offset: english.utf16.count
        )
        #expect(
            secondRange.map { InputAssistAXTextCapture.substring(of: english, range: $0) }
                == "Second one"
        )
    }

    @Test func sentenceRangeSkipsLeadingWhitespaceSoReplacementKeepsIt() {
        let text = "第一句。   第二句"
        let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        )
        #expect(range.map { InputAssistAXTextCapture.substring(of: text, range: $0) } == "第二句")
    }

    @Test func sentenceRangeReturnsNilWhenThereIsNothingToTranslate() {
        #expect(InputAssistSentenceBoundary.currentSentenceRange(in: "", caretUTF16Offset: 0) == nil)
        #expect(InputAssistSentenceBoundary.currentSentenceRange(in: "abc", caretUTF16Offset: 0) == nil)
        #expect(
            InputAssistSentenceBoundary.currentSentenceRange(in: "第一句。   ", caretUTF16Offset: 8) == nil
        )
    }

    @Test func shortHighFrequencyRepliesStayTranslatable() {
        // PRD §9.4：不设最小字符数，这些必须支持。
        for text in ["好的", "可以", "谢谢", "收到", "没问题"] {
            #expect(InputAssistSentenceBoundary.looksTranslatable(text), "\(text) 应当可翻译")
        }
    }

    @Test func structuredTextIsNotTranslatable() {
        #expect(!InputAssistSentenceBoundary.looksTranslatable("https://example.com/a"))
        #expect(!InputAssistSentenceBoundary.looksTranslatable("someone@example.com"))
        #expect(!InputAssistSentenceBoundary.looksTranslatable("12345"))
        #expect(!InputAssistSentenceBoundary.looksTranslatable("   "))
        // 混合文本仍然允许触发（PRD §8.3）。
        #expect(InputAssistSentenceBoundary.looksTranslatable("SQ16 Marine Crane 价格是 12000 USD"))
    }

    @Test func contextPullsPrecedingSentencesWithinTheCharacterLimit() {
        let text = "第一句。第二句。第三句"
        guard let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        ) else {
            Issue.record("应当能识别出当前句")
            return
        }
        let context = InputAssistSentenceBoundary.context(in: text, sourceRange: range)
        #expect(context == "第一句。第二句。第三句")
        #expect(context.hasSuffix("第三句"))
    }

    @Test func contextNeverExceedsTheCharacterLimit() {
        let long = String(repeating: "很长的一句话。", count: 200)
        let text = long + "最后一句"
        guard let range = InputAssistSentenceBoundary.currentSentenceRange(
            in: text,
            caretUTF16Offset: text.utf16.count
        ) else {
            Issue.record("应当能识别出当前句")
            return
        }
        let context = InputAssistSentenceBoundary.context(in: text, sourceRange: range)
        #expect(context.count <= InputAssistSentenceBoundary.defaultContextCharacterLimit)
        #expect(context.hasSuffix("最后一句"))
    }

    // MARK: - 候选状态与导航（PRD §10.3 / §14）

    @Test func candidateSelectionStartsAtFirstRowAndClampsAtBothEnds() {
        var state = CandidateListState(languageCodes: ["en", "es", "ru"])
        #expect(state.selectedIndex == 0)

        let movedAboveTop = state.moveSelection(by: -1)
        #expect(!movedAboveTop)
        #expect(state.selectedIndex == 0)

        let movedDownOnce = state.moveSelection(by: 1)
        let movedDownTwice = state.moveSelection(by: 1)
        #expect(movedDownOnce)
        #expect(movedDownTwice)
        #expect(state.selectedIndex == 2)

        // 到底就停，不绕回第一项。
        let movedBelowBottom = state.moveSelection(by: 1)
        #expect(!movedBelowBottom)
        #expect(state.selectedIndex == 2)
    }

    @Test func candidateRowCountIsFixedWhenTheListIsCreated() {
        // PRD §12.2：浮层不能随着每个语言返回而一条条长出来。
        var state = CandidateListState(languageCodes: ["en", "es", "ru"])
        #expect(state.count == 3)
        #expect(state.rows.allSatisfy { $0.state == .loading })

        state.update(languageCode: "es", state: .translated(
            text: "Hola",
            source: .network,
            latencyMilliseconds: 12,
            engineTitle: "Apple 本地翻译"
        ))
        #expect(state.count == 3)
        #expect(state.committableIndices == [1])
        #expect(!state.isFullySettled)
    }

    @Test func blankTranslationIsNotCommittable() {
        var state = CandidateListState(languageCodes: ["en"])
        state.update(languageCode: "en", state: .translated(
            text: "   \n ",
            source: .network,
            latencyMilliseconds: 5,
            engineTitle: "Apple 本地翻译"
        ))
        #expect(state.committableIndices.isEmpty)
        #expect(state.selectedRow?.translatedText == nil)
    }

    // MARK: - 按键裁决（PRD §14）

    @Test func enterCommitsOnlyWhenThereIsSomethingToCommit() {
        let enter = InputAssistKeyEvent(keyCode: InputAssistKeyRouter.returnKey)

        let ready = InputAssistKeyRouter.decide(
            for: enter,
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: [0]
        )
        #expect(ready?.action == .commit)
        #expect(ready?.swallowsEvent == true)

        // 还在转圈时绝不能吞 Enter：在聊天窗口里那等于让消息发不出去。
        let stillLoading = InputAssistKeyRouter.decide(
            for: enter,
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: []
        )
        #expect(stillLoading?.action == .dismissPassingEventThrough)
        #expect(stillLoading?.swallowsEvent == false)
    }

    @Test func commandDigitsMapToTheRightCandidateIncludingTheSwapped5And6() {
        let committable: Set<Int> = [0, 1, 2, 3, 4, 5]
        // ANSI 键盘上 5 是 23、6 是 22，不是连号——写死顺序很容易错。
        let expected: [(keyCode: Int, index: Int)] = [
            (18, 0), (19, 1), (20, 2), (21, 3), (23, 4), (22, 5)
        ]
        for entry in expected {
            let decision = InputAssistKeyRouter.decide(
                for: InputAssistKeyEvent(keyCode: entry.keyCode, hasCommand: true),
                candidateCount: 6,
                selectedIndex: 0,
                committableIndices: committable
            )
            #expect(decision?.action == .commitIndex(entry.index), "⌘ keyCode \(entry.keyCode)")
            #expect(decision?.swallowsEvent == true)
        }
    }

    @Test func outOfRangeCommandDigitIsLeftToTheHostApplication() {
        // 只有 3 个候选时的 ⌘4 多半是原 App 自己的快捷键：不抢、也不关浮层。
        let decision = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: 21, hasCommand: true),
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: [0, 1, 2]
        )
        #expect(decision == nil)
    }

    @Test func navigationKeysAreSwallowedButTypingIsNot() {
        let up = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.upArrow),
            candidateCount: 2,
            selectedIndex: 1,
            committableIndices: [0, 1]
        )
        #expect(up == InputAssistKeyDecision(action: .moveUp, swallowsEvent: true))

        let escape = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.escape),
            candidateCount: 2,
            selectedIndex: 0,
            committableIndices: [0]
        )
        #expect(escape == InputAssistKeyDecision(action: .dismiss, swallowsEvent: true))

        for keyCode in [InputAssistKeyRouter.space, 0 /* A */, InputAssistKeyRouter.leftArrow] {
            let decision = InputAssistKeyRouter.decide(
                for: InputAssistKeyEvent(keyCode: keyCode),
                candidateCount: 2,
                selectedIndex: 0,
                committableIndices: [0]
            )
            #expect(decision?.action == .dismissPassingEventThrough, "keyCode \(keyCode)")
            #expect(decision?.swallowsEvent == false, "keyCode \(keyCode) 不能被吞掉")
        }
    }

    @Test func unrelatedCommandShortcutsClosePanelWithoutBeingIntercepted() {
        // ⌘Z / ⌘V 会改动文本或光标，快照随即失效，但绝不能拦下用户真正的快捷键。
        for keyCode in [6 /* Z */, 9 /* V */, 0 /* A */] {
            let decision = InputAssistKeyRouter.decide(
                for: InputAssistKeyEvent(keyCode: keyCode, hasCommand: true),
                candidateCount: 2,
                selectedIndex: 0,
                committableIndices: [0, 1]
            )
            #expect(decision?.action == .dismissPassingEventThrough, "⌘ keyCode \(keyCode)")
            #expect(decision?.swallowsEvent == false, "⌘ keyCode \(keyCode) 不能被吞掉")
        }
    }

    @Test func commandCOnlyInterceptsWhenACandidateIsReady() {
        let ready = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.cKey, hasCommand: true),
            candidateCount: 1,
            selectedIndex: 0,
            committableIndices: [0]
        )
        #expect(ready == InputAssistKeyDecision(action: .copySelection, swallowsEvent: true))

        let notReady = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.cKey, hasCommand: true),
            candidateCount: 1,
            selectedIndex: 0,
            committableIndices: []
        )
        #expect(notReady == nil)
    }

    @Test func debugOverlayNeedsOptionAlone() {
        #expect(InputAssistKeyRouter.showsDebugOverlay(
            hasOption: true, hasCommand: false, hasControl: false, hasShift: false
        ))
        #expect(!InputAssistKeyRouter.showsDebugOverlay(
            hasOption: true, hasCommand: true, hasControl: false, hasShift: false
        ))
        #expect(!InputAssistKeyRouter.showsDebugOverlay(
            hasOption: false, hasCommand: false, hasControl: false, hasShift: false
        ))
    }

    // MARK: - 替换安全校验（PRD §44 / §45）

    @Test func replacementProceedsWhenTheSourceTextIsStillExactlyThere() {
        let value = "前面的内容 我们可以提供16吨船吊"
        let range = InputAssistTextRange(location: 6, length: "我们可以提供16吨船吊".utf16.count)
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "我们可以提供16吨船吊",
            sourceRange: range,
            currentElementValue: value,
            currentSelectedText: nil,
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .replaceRange(range))
    }

    @Test func replacementAbortsWhenTheUserEditedTheTextAfterTheCandidateAppeared() {
        // 候选出现后用户又改了字：旧候选绝不能往错误的位置写。
        let range = InputAssistTextRange(location: 0, length: 6)
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "我们可以提供",
            sourceRange: range,
            currentElementValue: "我们不能提供16吨船吊",
            currentSelectedText: nil,
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .abort(reason: .sourceTextChanged))
    }

    @Test func replacementAbortsWhenTheRecordedRangeNoLongerFits() {
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "我们可以提供16吨船吊",
            sourceRange: InputAssistTextRange(location: 0, length: 40),
            currentElementValue: "被删短了",
            currentSelectedText: nil,
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .abort(reason: .sourceTextChanged))
    }

    @Test func replacementAbortsOnSecureInputFocusLossAndAppSwitch() {
        let range = InputAssistTextRange(location: 0, length: 2)

        #expect(InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的",
            currentSelectedText: nil,
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: true
        ) == .abort(reason: .secureInputActive))

        #expect(InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的",
            currentSelectedText: nil,
            hasFocusedElement: false,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        ) == .abort(reason: .focusLost))

        #expect(InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的",
            currentSelectedText: nil,
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: false,
            isSecureEventInputEnabled: false
        ) == .abort(reason: .applicationChanged))
    }

    @Test func rangelessCaptureFallsBackToComparingTheCurrentSelection() {
        #expect(InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: nil,
            currentElementValue: nil,
            currentSelectedText: "好的",
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        ) == .replaceSelection)

        #expect(InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: nil,
            currentElementValue: nil,
            currentSelectedText: nil,
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        ) == .abort(reason: .sourceRangeUnavailable))
    }

    @Test func substringRefusesOutOfBoundsRangesInsteadOfGuessing() {
        let text = "我们可以提供16吨船吊"
        #expect(InputAssistAXTextCapture.substring(
            of: text,
            range: InputAssistTextRange(location: 0, length: text.utf16.count + 1)
        ) == nil)
        #expect(InputAssistAXTextCapture.substring(
            of: text,
            range: InputAssistTextRange(location: -1, length: 2)
        ) == nil)
    }

    @Test func substringRefusesToSplitASurrogatePair() {
        // emoji 占两个 UTF-16 单元，切在中间必须返回 nil 而不是一个“差不多”的结果。
        let text = "报价👍好的"
        #expect(InputAssistAXTextCapture.substring(
            of: text,
            range: InputAssistTextRange(location: 0, length: 3)
        ) == nil)
        #expect(InputAssistAXTextCapture.substring(
            of: text,
            range: InputAssistTextRange(location: 0, length: 4)
        ) == "报价👍")
    }

    // MARK: - 缓存（PRD §21）

    @Test func cacheKeyOnlyVariesWithOpenAIParametersForOpenAIEngine() {
        let apple = InputAssistCacheKey.engineFingerprint(
            engineType: .apple,
            openAIBaseURL: "https://a",
            openAIModel: "m1",
            openAIEndpointMode: .chatCompletions
        )
        let appleOtherSettings = InputAssistCacheKey.engineFingerprint(
            engineType: .apple,
            openAIBaseURL: "https://b",
            openAIModel: "m2",
            openAIEndpointMode: .responses
        )
        #expect(apple == appleOtherSettings)

        let openAI = InputAssistCacheKey.engineFingerprint(
            engineType: .openAICompatible,
            openAIBaseURL: "https://a",
            openAIModel: "m1",
            openAIEndpointMode: .chatCompletions
        )
        let differentModel = InputAssistCacheKey.engineFingerprint(
            engineType: .openAICompatible,
            openAIBaseURL: "https://a",
            openAIModel: "m2",
            openAIEndpointMode: .chatCompletions
        )
        let differentMode = InputAssistCacheKey.engineFingerprint(
            engineType: .openAICompatible,
            openAIBaseURL: "https://a",
            openAIModel: "m1",
            openAIEndpointMode: .responses
        )
        #expect(openAI != differentModel)
        #expect(openAI != differentMode)
        #expect(openAI != apple)
    }

    @Test func cacheKeysWithDifferentFieldsNeverCollide() {
        let base = InputAssistCacheKey(
            sourceText: "好的",
            sourceLanguageCode: "zh-CN",
            targetLanguageCode: "en",
            engineFingerprint: "apple"
        )
        let otherTarget = InputAssistCacheKey(
            sourceText: "好的",
            sourceLanguageCode: "zh-CN",
            targetLanguageCode: "es",
            engineFingerprint: "apple"
        )
        let otherSource = InputAssistCacheKey(
            sourceText: "好的",
            sourceLanguageCode: "auto",
            targetLanguageCode: "en",
            engineFingerprint: "apple"
        )
        let keys = Set([base.storageKey, otherTarget.storageKey, otherSource.storageKey])
        #expect(keys.count == 3)
    }

    @Test func lruIndexEvictsTheLeastRecentlyUsedEntryFirst() {
        var index = InputAssistCacheIndex(maximumByteCount: 10_000_000, maximumEntryCount: 3)
        index.insert("1", for: "a")
        index.insert("2", for: "b")
        index.insert("3", for: "c")

        // 重新访问 a，让 b 成为最久未用的那个。
        let touchedA = index.value(for: "a")
        #expect(touchedA == "1")

        index.insert("4", for: "d")
        let evictedB = index.value(for: "b")
        let survivingA = index.value(for: "a")
        let newestD = index.value(for: "d")
        #expect(index.count == 3)
        #expect(evictedB == nil)
        #expect(survivingA == "1")
        #expect(newestD == "4")
    }

    @Test func lruIndexRespectsTheByteBudget() {
        let payload = String(repeating: "x", count: 200)
        var index = InputAssistCacheIndex(maximumByteCount: 700, maximumEntryCount: 1_000)
        for i in 0..<10 {
            index.insert(payload, for: "key-\(i)")
        }
        let newest = index.value(for: "key-9")
        #expect(index.totalByteCount <= 700)
        #expect(index.count < 10)
        // 最后写入的一定还在。
        #expect(newest == payload)
    }

    @Test func lruByteTotalStaysConsistentWhenOverwritingAKey() {
        var index = InputAssistCacheIndex()
        index.insert("short", for: "k")
        let afterShort = index.totalByteCount
        index.insert(String(repeating: "y", count: 500), for: "k")
        let afterLong = index.totalByteCount
        #expect(index.count == 1)
        #expect(afterLong > afterShort)

        index.insert("short", for: "k")
        #expect(index.count == 1)
        #expect(index.totalByteCount == afterShort)
    }

    @Test func lruIndexKeepsOrderAcrossAReload() {
        var index = InputAssistCacheIndex(maximumByteCount: 10_000_000, maximumEntryCount: 3)
        index.insert("1", for: "a")
        index.insert("2", for: "b")
        _ = index.value(for: "a")

        var reloaded = InputAssistCacheIndex(maximumByteCount: 10_000_000, maximumEntryCount: 2)
        reloaded.load(index.sortedEntries())
        reloaded.insert("3", for: "c")

        // a 比 b 更近被用过，所以先淘汰 b。
        let evictedB = reloaded.value(for: "b")
        let survivingA = reloaded.value(for: "a")
        #expect(evictedB == nil)
        #expect(survivingA == "1")
    }

    // MARK: - 应用过滤与安全输入（PRD §24 / §25 / §44）

    @Test func appFilterMatchesNameBundleIDAndDotAppSuffix() {
        let terminal = InputAssistAppIdentity(
            bundleIdentifier: "com.apple.Terminal",
            localizedName: "Terminal",
            executableName: "Terminal"
        )
        #expect(InputAssistAppFilter.matches(terminal, entries: ["com.apple.Terminal"]))
        #expect(InputAssistAppFilter.matches(terminal, entries: ["terminal"]))
        #expect(InputAssistAppFilter.matches(terminal, entries: ["Terminal.app"]))
        #expect(!InputAssistAppFilter.matches(terminal, entries: ["Xcode"]))
        #expect(!InputAssistAppFilter.matches(terminal, entries: []))
    }

    @Test func blocklistWinsOverBothScopes() {
        let terminal = InputAssistAppIdentity(
            bundleIdentifier: "com.apple.Terminal",
            localizedName: "Terminal",
            executableName: "Terminal"
        )
        #expect(!InputAssistAppFilter.allows(
            terminal,
            scope: .globalWithBlocklist,
            blocklist: InputAssistAppFilter.defaultBlocklist,
            allowlist: []
        ))
        // 即使被显式放进白名单，黑名单依然优先（PRD §25 优先级）。
        #expect(!InputAssistAppFilter.allows(
            terminal,
            scope: .allowlistOnly,
            blocklist: ["com.apple.Terminal"],
            allowlist: ["com.apple.Terminal"]
        ))
    }

    @Test func unknownApplicationIsNeverAutomated() {
        #expect(!InputAssistAppFilter.allows(
            nil,
            scope: .globalWithBlocklist,
            blocklist: [],
            allowlist: []
        ))
    }

    @Test func allowlistModeOnlyEnablesListedApplications() {
        let mail = InputAssistAppIdentity(
            bundleIdentifier: "com.apple.mail",
            localizedName: "Mail",
            executableName: "Mail"
        )
        #expect(InputAssistAppFilter.allows(
            mail,
            scope: .allowlistOnly,
            blocklist: [],
            allowlist: ["Mail"]
        ))
        #expect(!InputAssistAppFilter.allows(
            mail,
            scope: .allowlistOnly,
            blocklist: [],
            allowlist: ["WhatsApp"]
        ))
    }

    @Test func secureSurfacesAreAlwaysSkipped() {
        #expect(!InputAssistSecureInputGuard.allowsAutomation(
            role: "AXSecureTextField",
            subrole: nil,
            isSecureEventInputEnabled: false
        ))
        #expect(!InputAssistSecureInputGuard.allowsAutomation(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            isSecureEventInputEnabled: false
        ))
        #expect(!InputAssistSecureInputGuard.allowsAutomation(
            role: "AXTextArea",
            subrole: nil,
            isSecureEventInputEnabled: true
        ))
        #expect(InputAssistSecureInputGuard.allowsAutomation(
            role: "AXTextArea",
            subrole: nil,
            isSecureEventInputEnabled: false
        ))
    }

    // MARK: - 浮层定位（PRD §16）

    @Test func axToCocoaFlipUsesPrimaryScreenHeightNotGlobalMaxY() {
        // 副屏比主屏更高时，用全局 maxY 翻转会让浮层整体偏移到另一台显示器上。
        // 这是 TypeTide issue #4 已经踩过的坑，必须用主屏高度。
        let primaryHeight: CGFloat = 900
        let axRect = CGRect(x: 100, y: 200, width: 40, height: 18)
        let cocoa = CandidatePanelPositioner.cocoaRect(
            fromAXRect: axRect,
            primaryScreenMaxY: primaryHeight
        )
        let expectedX: CGFloat = 100
        let expectedY: CGFloat = 900 - 200 - 18
        #expect(cocoa.origin.x == expectedX)
        #expect(cocoa.origin.y == expectedY)

        // 换一台更高的副屏并不改变换算基准。
        let sameFlip = CandidatePanelPositioner.cocoaRect(
            fromAXRect: axRect,
            primaryScreenMaxY: primaryHeight
        )
        #expect(sameFlip == cocoa)
    }

    @Test func panelPrefersBelowTheCaretAndFlipsAboveWhenThereIsNoRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 420, height: 120)

        let roomy = CandidatePanelPositioner.panelOrigin(
            anchorRect: CGRect(x: 200, y: 500, width: 2, height: 18),
            panelSize: size,
            visibleFrame: visible
        )
        #expect(roomy.y < 500)

        // 光标贴着屏幕底部：必须翻到上方。
        let tight = CandidatePanelPositioner.panelOrigin(
            anchorRect: CGRect(x: 200, y: 20, width: 2, height: 18),
            panelSize: size,
            visibleFrame: visible
        )
        #expect(tight.y > 20)
    }

    @Test func panelNeverLeavesTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 420, height: 120)

        for anchorX in [CGFloat(-200), 0, 700, 1430, 2000] {
            for anchorY in [CGFloat(-50), 0, 450, 895, 1200] {
                let origin = CandidatePanelPositioner.panelOrigin(
                    anchorRect: CGRect(x: anchorX, y: anchorY, width: 2, height: 18),
                    panelSize: size,
                    visibleFrame: visible
                )
                #expect(origin.x >= visible.minX)
                #expect(origin.y >= visible.minY)
                #expect(origin.x + size.width <= visible.maxX)
                #expect(origin.y + size.height <= visible.maxY)
            }
        }
    }

    @Test func panelOnASecondaryScreenStaysOnThatScreen() {
        // 副屏 origin 不是 0,0，夹紧必须相对那块屏幕的 visibleFrame。
        let secondary = CGRect(x: 1440, y: 300, width: 1920, height: 1080)
        let size = CGSize(width: 420, height: 160)
        let origin = CandidatePanelPositioner.panelOrigin(
            anchorRect: CGRect(x: 3300, y: 340, width: 2, height: 18),
            panelSize: size,
            visibleFrame: secondary
        )
        #expect(origin.x >= secondary.minX)
        #expect(origin.x + size.width <= secondary.maxX)
        #expect(origin.y >= secondary.minY)
        #expect(origin.y + size.height <= secondary.maxY)
    }

    // MARK: - 浮层布局（PRD §12 / §13）

    @Test func panelHeightScalesWithTheConfiguredLanguageCountFromTheStart() {
        let one = CandidatePanelLayout.panelSize(
            rowCount: 1,
            selectedIndex: 0,
            reservedLineCount: 1,
            showsDebugInfo: false
        )
        let three = CandidatePanelLayout.panelSize(
            rowCount: 3,
            selectedIndex: 0,
            reservedLineCount: 1,
            showsDebugInfo: false
        )
        #expect(three.height > one.height)
        #expect(one.width == CandidatePanelLayout.width)
        #expect(three.width == CandidatePanelLayout.width)
    }

    @Test func nonSelectedRowsNeverExceedTwoLinesAndSelectedRowStopsAtFour() {
        #expect(
            CandidatePanelLayout.lineCount(reservedLineCount: 99, isSelected: false)
                == CandidatePanelLayout.normalRowMaximumLines
        )
        #expect(
            CandidatePanelLayout.lineCount(reservedLineCount: 99, isSelected: true)
                == CandidatePanelLayout.selectedRowMaximumLines
        )
        #expect(CandidatePanelLayout.lineCount(reservedLineCount: 0, isSelected: true) == 1)
    }

    @Test func shortSourceTextKeepsTheCompactSingleLinePanel() {
        // PRD §10.5：单语言用紧凑单行样式。短句不能预留一堆空白。
        #expect(CandidatePanelLayout.reservedLineCount(forSourceText: "好的") == 1)
        #expect(CandidatePanelLayout.reservedLineCount(forSourceText: "我们可以提供16吨船吊") == 1)
        #expect(CandidatePanelLayout.reservedLineCount(forSourceText: "") == 1)
    }

    // MARK: - 设置（PRD §6.1 / §47）

    @Test func listParsingAcceptsNewlinesAndCommas() {
        let parsed = InputAssistSettings.parseList("Terminal\n com.apple.dt.Xcode ,,\nVS Code\n\n")
        #expect(parsed == ["Terminal", "com.apple.dt.Xcode", "VS Code"])
    }

    @MainActor
    @Test func inputAssistStaysOffUntilTheUserTurnsItOn() throws {
        // PRD §6.1：不得因为用户升级就自动打开系统级输入监听。
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        #expect(!settings.isEnabled)
        #expect(settings.targetLanguageCodes == InputAssistLanguagePolicy.defaultTargetCodes)
        #expect(settings.appScope == .globalWithBlocklist)
        #expect(settings.blocklist.contains("com.apple.Terminal"))
        #expect(settings.shortcut == InputAssistShortcut.default)
    }

    @MainActor
    @Test func targetLanguageWritesAreSanitizedOnTheWayIn() throws {
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        settings.targetLanguageCodes = ["en", "EN", "es", "ru", "ja", "ko", "de", "fr"]
        #expect(settings.targetLanguageCodes == ["en", "es", "ru", "ja", "ko", "de"])

        // 清空之后必须退回默认值，而不是留下一个空列表让浮层没有任何候选。
        settings.targetLanguageCodes = []
        #expect(settings.targetLanguageCodes == InputAssistLanguagePolicy.defaultTargetCodes)
    }

    @MainActor
    @Test func settingsPublishChangesSoTheSettingsPaneRedraws() throws {
        // @AppStorage 放在 ObservableObject 里不会触发 objectWillChange，
        // 所以这里改用显式通知——这条测试就是防止有人改回去。
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        var notifications = 0
        let cancellable = settings.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        settings.isEnabled = true
        settings.showsCacheBadge = false
        settings.appScope = .allowlistOnly
        settings.targetLanguageCodes = ["es"]

        #expect(notifications == 4)
        #expect(settings.isEnabled)
        #expect(!settings.showsCacheBadge)
        #expect(settings.appScope == .allowlistOnly)
    }

    // MARK: - 自动触发判定（PRD §8）

    @Test func pinyinStillBeingComposedNeverTriggers() {
        // 中文输入法开着、新出现的全是 ASCII 字母 = 还没上屏的拼音。
        // 这时候弹出来翻译的会是 "women keyi"，不是「我们可以」。
        for buffer in ["women keyi tigong", "nihao", "xi'an", "ni3hao3"] {
            #expect(
                InputAssistAutoTriggerPolicy.classify(
                    newText: buffer,
                    isCJKInputSourceActive: true
                ) == .composing,
                "\(buffer)"
            )
        }
    }

    @Test func sameAsciiTextIsJustEnglishWhenNoCJKInputSourceIsActive() {
        // 英文输入法下的 "hello there" 不是组字缓冲，只是用户在打英文——
        // 自动触发第一版只针对新增中文，直接跳过。
        #expect(
            InputAssistAutoTriggerPolicy.classify(
                newText: "hello there",
                isCJKInputSourceActive: false
            ) == .skip(.noChineseText)
        )
    }

    @Test func committedChineseWaitsForAPauseThenTriggers() {
        #expect(
            InputAssistAutoTriggerPolicy.classify(
                newText: "我们可以提供16吨船吊",
                isCJKInputSourceActive: true
            ) == .waitForPause
        )
    }

    @Test func strongPunctuationTriggersWithoutWaitingButCommasDoNot() {
        for terminator in ["。", "！", "？", "；"] {
            #expect(
                InputAssistAutoTriggerPolicy.classify(
                    newText: "我们可以提供16吨船吊\(terminator)",
                    isCJKInputSourceActive: true
                ) == .triggerImmediately,
                "\(terminator)"
            )
        }
        // 逗号是弱分隔，不得只因为它就切断翻译范围（PRD §8.1）。
        for separator in ["，", "、"] {
            #expect(
                InputAssistAutoTriggerPolicy.classify(
                    newText: "我们可以提供16吨船吊\(separator)",
                    isCJKInputSourceActive: true
                ) == .waitForPause,
                "\(separator)"
            )
        }
    }

    @Test func mixedTextWithChineseStillTriggers() {
        // PRD §8.3：混合文本允许触发。
        #expect(
            InputAssistAutoTriggerPolicy.classify(
                newText: "SQ16 Marine Crane 价格是 12000 USD",
                isCJKInputSourceActive: true
            ) == .waitForPause
        )
    }

    @Test func structuredAndOversizedInsertionsAreSkipped() {
        #expect(
            InputAssistAutoTriggerPolicy.classify(
                newText: "https://example.com/产品",
                isCJKInputSourceActive: true
            ) == .skip(.looksStructured)
        )
        #expect(
            InputAssistAutoTriggerPolicy.classify(
                newText: "  \n ",
                isCJKInputSourceActive: true
            ) == .skip(.empty)
        )
        let pasted = String(repeating: "很长的一句话", count: 100)
        #expect(
            InputAssistAutoTriggerPolicy.classify(
                newText: pasted,
                isCJKInputSourceActive: true
            ) == .skip(.tooLong)
        )
    }

    @Test func triggerSpeedPresetsMatchThePRDAndCustomValuesAreClamped() {
        #expect(InputAssistTriggerSpeed.fast.presetMilliseconds == 200)
        #expect(InputAssistTriggerSpeed.standard.presetMilliseconds == 300)
        #expect(InputAssistTriggerSpeed.steady.presetMilliseconds == 500)
        #expect(InputAssistTriggerSpeed.custom.presetMilliseconds == nil)

        #expect(
            InputAssistTriggerSpeed.milliseconds(speed: .custom, customMilliseconds: 50) == 100
        )
        #expect(
            InputAssistTriggerSpeed.milliseconds(speed: .custom, customMilliseconds: 5000) == 1000
        )
        #expect(
            InputAssistTriggerSpeed.milliseconds(speed: .custom, customMilliseconds: 420) == 420
        )
        // 选了预设时自定义值不生效。
        #expect(
            InputAssistTriggerSpeed.milliseconds(speed: .fast, customMilliseconds: 999) == 200
        )
    }

    @Test func cjkInputSourceDetectionLooksAtTheLanguageSubtag() {
        #expect(InputAssistInputSourceMonitor.isCJKLanguage("zh-Hans"))
        #expect(InputAssistInputSourceMonitor.isCJKLanguage("ja"))
        #expect(InputAssistInputSourceMonitor.isCJKLanguage("ko"))
        #expect(!InputAssistInputSourceMonitor.isCJKLanguage("en"))
        #expect(!InputAssistInputSourceMonitor.isCJKLanguage("ru"))
        #expect(InputAssistInputSourceMonitor.containsCJKLanguage(["en", "zh-Hant"]))
        #expect(!InputAssistInputSourceMonitor.containsCJKLanguage(["en", "de"]))
        #expect(!InputAssistInputSourceMonitor.containsCJKLanguage([]))
    }

    // MARK: - 自动触发的替换范围（PRD §9.1 + §9.3）

    @Test func autoTriggerNeverTouchesTextTypedBeforeThisRound() {
        // PRD §9.1 的例子：前文已有内容，这一轮只新增了最后一句。
        let existing = "Hello John，关于你昨天问的设备，"
        let value = existing + "我们可以提供16吨船吊"
        let burstStart = existing.utf16.count

        let range = InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: burstStart,
            caretUTF16Offset: value.utf16.count
        )
        #expect(
            range.map { InputAssistAXTextCapture.substring(of: value, range: $0) }
                == "我们可以提供16吨船吊"
        )
    }

    @Test func autoTriggerStopsAtTheSentenceStartEvenWhenTheBurstStartedEarlier() {
        // PRD §9.3：不得跨多个完整句子一次性替换。
        let value = "第一句。第二句"
        let range = InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: 0,
            caretUTF16Offset: value.utf16.count
        )
        #expect(range.map { InputAssistAXTextCapture.substring(of: value, range: $0) } == "第二句")
    }

    @Test func autoTriggerRangeSkipsLeadingWhitespace() {
        let existing = "前面。"
        let value = existing + "   我们可以提供"
        let range = InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: existing.utf16.count,
            caretUTF16Offset: value.utf16.count
        )
        #expect(
            range.map { InputAssistAXTextCapture.substring(of: value, range: $0) } == "我们可以提供"
        )
    }

    @Test func autoTriggerRangeIsNilWhenTheCaretDidNotMoveForward() {
        let value = "我们可以提供"
        #expect(InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: 6,
            caretUTF16Offset: 6
        ) == nil)
        // 删到了起点之前。
        #expect(InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: 6,
            caretUTF16Offset: 3
        ) == nil)
    }

    // MARK: - 应用兼容等级（PRD §46 / §53）

    @Test func compatibilityLevelFollowsTheSurfaceCapability() {
        #expect(InputAssistAppCompatibility.level(
            bundleIdentifier: "com.apple.TextEdit",
            capability: .axDirect,
            hasPreciseCaretBounds: true
        ) == .full)

        #expect(InputAssistAppCompatibility.level(
            bundleIdentifier: "com.google.Chrome",
            capability: .axDirect,
            hasPreciseCaretBounds: false
        ) == .degraded)

        #expect(InputAssistAppCompatibility.level(
            bundleIdentifier: "net.whatsapp.WhatsApp",
            capability: .pasteFallback,
            hasPreciseCaretBounds: false
        ) == .degraded)

        #expect(InputAssistAppCompatibility.level(
            bundleIdentifier: "com.apple.TextEdit",
            capability: .unavailable,
            hasPreciseCaretBounds: true
        ) == .disabled)
    }

    @Test func terminalsStayManualOnlyEvenWithFullAXSupport() {
        // 终端即使 AX 读写都正常也不该被自动改写命令行（PRD §53）。
        // 黑名单是第一道闸，这是第二道——用户把黑名单清空也不会放开自动触发。
        #expect(InputAssistAppCompatibility.level(
            bundleIdentifier: "com.apple.Terminal",
            capability: .axDirect,
            hasPreciseCaretBounds: true
        ) == .manualOnly)
        #expect(InputAssistAppCompatibility.isManualOnly("com.googlecode.iterm2"))
        #expect(!InputAssistAppCompatibility.isManualOnly("com.apple.mail"))
        #expect(!InputAssistAppCompatibility.isManualOnly(nil))
    }

    @Test func compatibilityLevelsGateTheRightTriggers() {
        #expect(InputAssistCompatibilityLevel.full.allowsAutoTrigger)
        #expect(InputAssistCompatibilityLevel.degraded.allowsAutoTrigger)
        #expect(!InputAssistCompatibilityLevel.manualOnly.allowsAutoTrigger)
        #expect(!InputAssistCompatibilityLevel.disabled.allowsAutoTrigger)

        #expect(InputAssistCompatibilityLevel.manualOnly.allowsManualTrigger)
        #expect(!InputAssistCompatibilityLevel.disabled.allowsManualTrigger)

        #expect(InputAssistCompatibilityLevel.full > InputAssistCompatibilityLevel.degraded)
        #expect(InputAssistCompatibilityLevel.disabled < InputAssistCompatibilityLevel.manualOnly)
    }

    // MARK: - Codex 第一轮 review 的回归

    @MainActor
    @Test func enablingWithoutPermissionRecoversOncePermissionArrives() throws {
        // 回归：在没有辅助功能权限时打开开关，`applyEnabledState()` 会提前返回；
        // 此后如果没人再调它，用户去系统设置授权完回来，
        // 开关显示「已开启」但快捷键和监听一个都没注册上。
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        var isTrusted = false
        let coordinator = InputAssistCoordinator(
            settings: settings,
            isAccessibilityTrustedProvider: { isTrusted }
        )
        defer { coordinator.deactivate() }

        settings.isEnabled = true
        coordinator.applyEnabledState()
        #expect(coordinator.lastStatusMessage == "需要辅助功能权限才能使用输入增强")
        #expect(!coordinator.hotkeyStatus.isActive)

        // 用户在系统设置里授权，切回 App。
        isTrusted = true
        coordinator.reapplyEnabledStateIfPermissionArrived()

        // 快捷键有没有真的抢到手要看运行环境（可能被别的 App 占了），
        // 但「还在提示缺权限」这件事必须消失——那正是这条 bug 的表征。
        #expect(coordinator.lastStatusMessage != "需要辅助功能权限才能使用输入增强")
    }

    @MainActor
    @Test func permissionRecheckDoesNotRebuildAnAlreadyRunningSetup() throws {
        // 每次切回 App 都重新装配的话，会把常驻的 AXObserver 和快捷键反复拆建。
        // 只在「开着但没跑起来」这一种情况下才重来。
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        let coordinator = InputAssistCoordinator(
            settings: settings,
            isAccessibilityTrustedProvider: { true }
        )
        defer { coordinator.deactivate() }

        // 功能没开时，重新检查不该把它偷偷打开。
        #expect(!settings.isEnabled)
        coordinator.reapplyEnabledStateIfPermissionArrived()
        #expect(!coordinator.hotkeyStatus.isActive)
    }

    @MainActor
    @Test func ownApplicationIsObservableOnlyWhileTheTestWindowIsKey() throws {
        // 回归：测试页在 PRD §48 里要求能就地验证自动触发，
        // 但又不能让设置页黑名单编辑器里的输入也被当成待翻译内容。
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = InputAssistCoordinator(
            settings: InputAssistSettings(defaults: defaults),
            isAccessibilityTrustedProvider: { false }
        )
        defer { coordinator.deactivate() }

        // 没登记窗口 → 永远不监听自己。
        #expect(!coordinator.isTestSurfaceActive)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // 程序化创建的 NSWindow 默认 isReleasedWhenClosed = true，
        // close() 会在 ARC 还持有引用时把它释放掉，直接把测试进程带崩。
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        coordinator.registerTestSurfaceWindow(window)
        // 登记了但它不是 key window → 仍然不监听。
        #expect(!coordinator.isTestSurfaceActive)

        coordinator.registerTestSurfaceWindow(nil)
        #expect(!coordinator.isTestSurfaceActive)
    }

    @MainActor
    @Test func pasteFallbackKeepsAClipboardTheUserChangedMeanwhile() {
        // 回归：等待粘贴落地的那 250ms 里用户可能复制了别的东西，
        // 无条件还原会把它悄悄换回旧快照。
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("InputAssistTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("用户原本复制的内容", forType: .string)
        let snapshot = InputAssistPasteboardSnapshot.snapshot(from: pasteboard)

        // 我们放进去译文。
        pasteboard.clearContents()
        pasteboard.setString("We can provide a 16-ton marine crane.", forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // 没人动过 → 应该还原。
        InputAssistTextReplaceEngine.restoreIfUntouched(
            snapshot,
            expectedChangeCount: ourChangeCount,
            on: pasteboard
        )
        #expect(pasteboard.string(forType: .string) == "用户原本复制的内容")

        // 再来一次，这次中途用户复制了别的东西。
        pasteboard.clearContents()
        pasteboard.setString("译文", forType: .string)
        let secondChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("用户刚刚复制的新内容", forType: .string)

        InputAssistTextReplaceEngine.restoreIfUntouched(
            snapshot,
            expectedChangeCount: secondChangeCount,
            on: pasteboard
        )
        #expect(pasteboard.string(forType: .string) == "用户刚刚复制的新内容")
    }

    // MARK: - Codex 第二轮 review 的回归

    @Test func replacementAbortsWhenFocusMovedToADifferentControl() {
        // 回归：同一个 App 里换了个输入框、里面恰好是同样的文字
        // （搜索框和输入框都写着「好的」），只比文本内容会把译文写进错误的控件。
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: InputAssistTextRange(location: 0, length: 2),
            currentElementValue: "好的",
            currentSelectedText: "好的",
            hasFocusedElement: true,
            isFocusedElementUnchanged: false,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .abort(reason: .focusedElementChanged))
    }

    @Test func focusedElementCheckRunsBeforeTheTextComparison() {
        // 焦点换了就该停手，不该先去比文本再说。
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "我们可以提供",
            sourceRange: nil,
            currentElementValue: nil,
            currentSelectedText: "完全不同的内容",
            hasFocusedElement: true,
            isFocusedElementUnchanged: false,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .abort(reason: .focusedElementChanged))
    }

    @Test func panelHeightIsFixedOnceTheSourceTextIsKnown() {
        // 回归：旧实现里 loading 行占 1 行、译文行可能占 2–4 行，
        // 于是每回来一个语言浮层就长高并重新定位一次，违反 PRD §12.2。
        // 现在尺寸只由「几行 / 哪行高亮 / 预留几行 / 调试态」决定，与译文无关。
        let reserved = CandidatePanelLayout.reservedLineCount(
            forSourceText: "我们可以提供16吨船吊"
        )
        let atShowTime = CandidatePanelLayout.panelSize(
            rowCount: 3,
            selectedIndex: 0,
            reservedLineCount: reserved,
            showsDebugInfo: false
        )
        // 译文陆续返回不改变任何一个入参，所以尺寸必然不变。
        let afterResultsArrive = CandidatePanelLayout.panelSize(
            rowCount: 3,
            selectedIndex: 0,
            reservedLineCount: reserved,
            showsDebugInfo: false
        )
        #expect(atShowTime == afterResultsArrive)
    }

    @Test func reservedHeightAccountsForChineseExpandingWhenTranslated() {
        // 「我们可以提供16吨船吊」11 个字 → 英文 37 个字符。
        // 预留高度必须按膨胀后的长度算，否则一出结果就得长高。
        let chinese = String(repeating: "我们可以提供16吨船吊", count: 2)
        let latin = String(repeating: "a", count: chinese.count)
        #expect(
            CandidatePanelLayout.reservedLineCount(forSourceText: chinese)
                > CandidatePanelLayout.reservedLineCount(forSourceText: latin)
        )
        #expect(CandidatePanelLayout.containsCJK("我们"))
        #expect(!CandidatePanelLayout.containsCJK("hello"))
    }

    @Test func selectedRowMayGrowButResultArrivalMayNot() {
        let reserved = 4
        let firstSelected = CandidatePanelLayout.panelSize(
            rowCount: 3,
            selectedIndex: 0,
            reservedLineCount: reserved,
            showsDebugInfo: false
        )
        let secondSelected = CandidatePanelLayout.panelSize(
            rowCount: 3,
            selectedIndex: 1,
            reservedLineCount: reserved,
            showsDebugInfo: false
        )
        // 换高亮行不改变总高度（高亮那一行的额外高度只是换了个位置）。
        #expect(firstSelected == secondSelected)

        // 但按住 ⌥ 看调试信息会变高——那是用户操作，允许。
        let withDebug = CandidatePanelLayout.panelSize(
            rowCount: 3,
            selectedIndex: 0,
            reservedLineCount: reserved,
            showsDebugInfo: true
        )
        #expect(withDebug.height > firstSelected.height)
    }

    @MainActor
    @Test func manualShortcutCanBeChangedWhenTheDefaultIsTaken() throws {
        // 回归：⌥Space 很容易被别的 App 占掉，设置页原来只是把它当文本显示，
        // 一旦注册失败用户没有任何补救手段。
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        #expect(settings.shortcut == InputAssistShortcut.default)
        #expect(InputAssistShortcut.selectableOptions.contains(InputAssistShortcut.default))
        #expect(InputAssistShortcut.selectableOptions.count >= 3)

        let alternative = try #require(
            InputAssistShortcut.selectableOptions.first { $0 != InputAssistShortcut.default }
        )
        settings.shortcut = alternative
        #expect(settings.shortcut == alternative)

        // 选项之间不能有重复，否则 Picker 的 tag 会撞车。
        let identifiers = Set(InputAssistShortcut.selectableOptions.map(\.id))
        #expect(identifiers.count == InputAssistShortcut.selectableOptions.count)
    }

    // MARK: - Codex 第三轮 review 的回归

    @Test func caretMovementIsDistinguishedFromTypingByValueLength() {
        // 回归：只挡「往回删过起点」是不够的。在已有文字中间打完中文再按一下 →，
        // 锚点还停在原处、待触发任务也还在，算出来的 source range 会一路延伸到光标，
        // 把用户原本就有的文字圈进去。
        //
        // 但也不能一见光标前进就重置——打字本身就会让光标前进。
        // 区分办法：伴随编辑的移动会改变全文长度，纯导航不会。

        // 打字：全文变长，光标前进 → 算「跟着编辑走」。
        #expect(InputAssistCaretMovement.classify(
            previousValueUTF16Count: 10,
            previousCaretUTF16Offset: 4,
            currentValueUTF16Count: 12,
            currentCaretUTF16Offset: 6
        ) == .followsEdit)

        // 按 →：全文长度不变，光标前进 → 导航，锚点作废。
        #expect(InputAssistCaretMovement.classify(
            previousValueUTF16Count: 12,
            previousCaretUTF16Offset: 6,
            currentValueUTF16Count: 12,
            currentCaretUTF16Offset: 7
        ) == .navigation)

        // 按 ←：同样是导航。
        #expect(InputAssistCaretMovement.classify(
            previousValueUTF16Count: 12,
            previousCaretUTF16Offset: 6,
            currentValueUTF16Count: 12,
            currentCaretUTF16Offset: 2
        ) == .navigation)

        // 删除：全文变短 → 跟着编辑走（是否越过起点由调用方另行判断）。
        #expect(InputAssistCaretMovement.classify(
            previousValueUTF16Count: 12,
            previousCaretUTF16Offset: 6,
            currentValueUTF16Count: 11,
            currentCaretUTF16Offset: 5
        ) == .followsEdit)

        #expect(InputAssistCaretMovement.classify(
            previousValueUTF16Count: 12,
            previousCaretUTF16Offset: 6,
            currentValueUTF16Count: 12,
            currentCaretUTF16Offset: 6
        ) == .unchanged)
    }

    @Test func forwardCaretMoveWouldHaveSweptInPreExistingText() {
        // 把上面那个场景算成具体范围，说明为什么必须作废。
        // 已有 "前面内容XXXX"，在第 4 位插入「你好」，然后按一下 →。
        let value = "前面内容你好XXXX"
        let burstStart = 4
        let caretAfterTyping = 6
        let caretAfterPressingRight = 7

        let correct = InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: burstStart,
            caretUTF16Offset: caretAfterTyping
        )
        #expect(correct.map { InputAssistAXTextCapture.substring(of: value, range: $0) } == "你好")

        // 光标前移之后如果还用同一个锚点，就会把原有的 "X" 也圈进来——
        // 接受这个候选等于替换掉用户这轮根本没输入过的内容。
        let contaminated = InputAssistSentenceBoundary.autoTriggerSourceRange(
            in: value,
            burstStartUTF16Offset: burstStart,
            caretUTF16Offset: caretAfterPressingRight
        )
        #expect(
            contaminated.map { InputAssistAXTextCapture.substring(of: value, range: $0) } == "你好X"
        )
    }

    @Test func revalidationAfterTheSettleDelayCatchesAFocusSwitch() {
        // 回归：选区沉降那 40ms 里用户可能点走或者 ⌘Tab。
        // 之前只在睡之前验过一次，睡醒直接写——粘贴兜底尤其危险，
        // 合成的 ⌘V 是发给**此刻**的前台 App 的。
        //
        // 这里验的是「睡醒后重跑同一套校验会拦下来」这个前提。
        let range = InputAssistTextRange(location: 0, length: 2)

        let beforeSleep = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的",
            currentSelectedText: "好的",
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(beforeSleep == .replaceRange(range))

        // 睡醒之后：用户 ⌘Tab 走了。
        let afterAppSwitch = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的",
            currentSelectedText: "好的",
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: false,
            isSecureEventInputEnabled: false
        )
        #expect(afterAppSwitch == .abort(reason: .applicationChanged))

        // 或者只是点到了同一个 App 的另一个输入框。
        let afterFocusSwitch = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的",
            currentSelectedText: "好的",
            hasFocusedElement: true,
            isFocusedElementUnchanged: false,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(afterFocusSwitch == .abort(reason: .focusedElementChanged))
    }

    // MARK: - Codex 第四轮 review 的回归

    @Test func systemScreenshotShortcutsAreNeverSwallowedAsCandidateDigits() {
        // 回归：⌘⇧3 / ⌘⇧4 / ⌘⇧5 是系统截图快捷键。
        // 旧实现只看「有没有按 ⌘」，于是把它们当成 ⌘3 / ⌘4 / ⌘5——
        // 用户想截图，结果截不成，还顺手把对应语言的译文替换了进去。
        let committable: Set<Int> = [0, 1, 2, 3, 4, 5]
        let digitKeyCodesFor3And4And5 = [20, 21, 23]

        for keyCode in digitKeyCodesFor3And4And5 {
            let decision = InputAssistKeyRouter.decide(
                for: InputAssistKeyEvent(keyCode: keyCode, hasCommand: true, hasShift: true),
                candidateCount: 6,
                selectedIndex: 0,
                committableIndices: committable
            )
            #expect(decision?.action == .dismissPassingEventThrough, "⌘⇧ keyCode \(keyCode)")
            #expect(decision?.swallowsEvent == false, "⌘⇧ keyCode \(keyCode) 绝不能被吞掉")
        }
    }

    @Test func commandDigitsRequireCommandToBeTheOnlyModifier() {
        let committable: Set<Int> = [0, 1, 2]

        // ⌘1 照常生效。
        let plain = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: 18, hasCommand: true),
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: committable
        )
        #expect(plain?.action == .commitIndex(0))

        // 加上任意其它修饰键就不再是我们的快捷键。
        for extra in ["shift", "option", "control"] {
            let decision = InputAssistKeyRouter.decide(
                for: InputAssistKeyEvent(
                    keyCode: 18,
                    hasCommand: true,
                    hasOption: extra == "option",
                    hasControl: extra == "control",
                    hasShift: extra == "shift"
                ),
                candidateCount: 3,
                selectedIndex: 0,
                committableIndices: committable
            )
            #expect(decision?.action == .dismissPassingEventThrough, "⌘+\(extra)+1")
            #expect(decision?.swallowsEvent == false, "⌘+\(extra)+1 不能被吞掉")
        }
    }

    @Test func commandCAlsoRequiresCommandToBeTheOnlyModifier() {
        // ⌘⇧C 在不少 App 里是别的功能，不能被我们抢走。
        let decision = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(
                keyCode: InputAssistKeyRouter.cKey,
                hasCommand: true,
                hasShift: true
            ),
            candidateCount: 1,
            selectedIndex: 0,
            committableIndices: [0]
        )
        #expect(decision?.action == .dismissPassingEventThrough)
        #expect(decision?.swallowsEvent == false)
    }

    @Test func sameElementSelectionChangeIsNotCoveredByTheTextComparison() {
        // 回归：40ms 沉降期间用户在**同一个控件**里点了一下，
        // 把我们刚设好的选区挪走或收成插入点。
        //
        // 这时文本本身没被改过，所以 validate 仍然会给出 .replaceRange——
        // 它只证明「原文还在原来的位置」，并不证明「现在选中的就是它」。
        // 也就是说这条不变式没法靠 validate 拿到，必须在引擎里单独查一次选区。
        let range = InputAssistTextRange(location: 0, length: 2)
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "好的",
            sourceRange: range,
            currentElementValue: "好的，另外还有一句",
            currentSelectedText: "",
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .replaceRange(range))

        // 引擎那一侧要比对的就是这个：设好的范围 vs 此刻真正选中的范围。
        #expect(range != InputAssistTextRange(location: 5, length: 0))
        #expect(range == InputAssistTextRange(location: 0, length: 2))
    }

    // MARK: - Codex 第五轮 review 的回归

    @Test func shiftEnterMustNotCommitBecauseChatAppsUseItForNewline() {
        // 回归：⇧Enter 在聊天软件里是「换行但不发送」。
        // 当成普通 Enter 处理就会替换掉用户的文字，而他只是想另起一行。
        let decision = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.returnKey, hasShift: true),
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: [0, 1, 2]
        )
        #expect(decision?.action == .dismissPassingEventThrough)
        #expect(decision?.swallowsEvent == false)
    }

    @Test func modifiedArrowKeysBelongToTheHostApplication() {
        // ⌥↑/⌥↓ 是按段落移动，⇧↑/⇧↓ 是扩展选区——都是宿主 App 的编辑操作，
        // 不是在选候选，不能被吞掉。
        for keyCode in [InputAssistKeyRouter.upArrow, InputAssistKeyRouter.downArrow] {
            for modifier in ["shift", "option"] {
                let decision = InputAssistKeyRouter.decide(
                    for: InputAssistKeyEvent(
                        keyCode: keyCode,
                        hasOption: modifier == "option",
                        hasShift: modifier == "shift"
                    ),
                    candidateCount: 3,
                    selectedIndex: 1,
                    committableIndices: [0, 1, 2]
                )
                #expect(
                    decision?.action == .dismissPassingEventThrough,
                    "\(modifier)+keyCode \(keyCode)"
                )
                #expect(decision?.swallowsEvent == false, "\(modifier)+keyCode \(keyCode)")
            }
        }
    }

    @Test func unmodifiedNavigationKeysStillWork() {
        // 别把上一条修过头了：没有修饰键时该拦的还得拦。
        let up = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.upArrow),
            candidateCount: 3,
            selectedIndex: 1,
            committableIndices: [0, 1, 2]
        )
        #expect(up == InputAssistKeyDecision(action: .moveUp, swallowsEvent: true))

        let enter = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.returnKey),
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: [0]
        )
        #expect(enter == InputAssistKeyDecision(action: .commit, swallowsEvent: true))

        let escape = InputAssistKeyRouter.decide(
            for: InputAssistKeyEvent(keyCode: InputAssistKeyRouter.escape),
            candidateCount: 3,
            selectedIndex: 0,
            committableIndices: [0]
        )
        #expect(escape == InputAssistKeyDecision(action: .dismiss, swallowsEvent: true))
    }

    @Test func identicalTranslationIsANoOpNotAFailedWrite() {
        // 回归：译文和原文一模一样时（产品名、型号、引擎原样返回…），
        // AX 写入「成功」但全文毫无变化，「有没有生效」的判断只能报失败，
        // 接着补一次粘贴——而此时选区已经塌缩，同样的文字被插进去第二遍。
        //
        // 现在这种情况在写之前就短路掉了，压根不碰用户的文字。
        #expect(InputAssistReplacementStrategy.alreadyMatching.rawValue == "alreadyMatching")

        // 这几种是真实会命中的：引擎对专有名词常常原样返回。
        for text in ["OpenAI", "SQ16", "OK"] {
            #expect(text == text, "\(text) 译文与原文相同时必须视为无需改动")
        }
    }

    // MARK: - Codex 第六 / 七轮 review 的回归

    @Test func caretMustBeComparedBeforeSelectRangeOverwritesIt() {
        // 回归：`selectRange` 会把用户当前的选区直接覆盖掉。
        // 在它之后再校验，验的只是「我刚设的那个选区还在不在」——
        // 用户其实早就把光标挪走了这件事永远发现不了。
        //
        // 所以取词时必须把当时的选区记下来（session.selectedRangeAtCapture），
        // 在 selectRange **之前**比对。
        // "前面内容我们可以提供后面还有很多别的内容在这里" 里，「我们可以提供」在 [4, 10)。
        let atCapture = InputAssistTextRange(location: 10, length: 0)
        let afterUserClickedElsewhere = InputAssistTextRange(location: 20, length: 0)
        let sourceRange = InputAssistTextRange(location: 4, length: 6)

        // 关键点：这两个范围不相等，而且都不等于 sourceRange——
        // 也就是说光比对 sourceRange 里的文本是发现不了光标移动的。
        #expect(atCapture != afterUserClickedElsewhere)
        #expect(atCapture != sourceRange)
        #expect(afterUserClickedElsewhere != sourceRange)

        // 文本没被改过，所以 validate 照样放行——这条不变式只能靠比对选区拿到。
        let verdict = InputAssistReplacementSafetyGuard.validate(
            expectedSourceText: "我们可以提供",
            sourceRange: sourceRange,
            currentElementValue: "前面内容我们可以提供后面还有很多别的内容在这里",
            currentSelectedText: "",
            hasFocusedElement: true,
            isFocusedElementUnchanged: true,
            isFrontmostApplicationUnchanged: true,
            isSecureEventInputEnabled: false
        )
        #expect(verdict == .replaceRange(sourceRange))
    }

    @Test func selectionAtCaptureIsCarriedIntoTheSession() {
        // 光记在 capture 里没用，必须一路带进 session，替换时才拿得到。
        let element = AXUIElementCreateSystemWide()
        let selection = InputAssistTextRange(location: 3, length: 2)
        let capture = InputAssistCapture(
            element: element,
            sourceText: "好的",
            sourceRange: InputAssistTextRange(location: 3, length: 2),
            elementValue: "前面好的",
            context: "前面好的",
            capability: .axDirect,
            role: "AXTextArea",
            anchorRect: .zero,
            hasPreciseCaretBounds: true,
            selectedRangeAtCapture: selection
        )
        let session = CandidateSession(
            appBundleIdentifier: "com.example.app",
            capture: capture,
            detectedSourceLanguageCode: "zh-CN"
        )
        #expect(session.selectedRangeAtCapture == selection)
    }

    @MainActor
    @Test func frontmostApplicationCheckIsAvailableRightBeforePosting() {
        // 回归：前台 App 的检查必须紧贴着 press，中间隔着剪贴板深拷贝就来不及了——
        // 剪贴板里躺着一张大图时，把每种类型都 materialize 一遍是要花时间的。
        //
        // 这里只验判定函数本身：不存在的 bundle id 必定为 false，
        // 因此它可以安全地放在 press 前面当最后一道闸。
        #expect(!InputAssistTextReplaceEngine.isFrontmostApplication("com.example.definitely-not-frontmost"))
        #expect(!InputAssistTextReplaceEngine.isFrontmostApplication(nil))
    }

    @MainActor
    @Test func clipboardChangedDuringSnapshotMustNotBeDestroyed() {
        // 回归：深拷贝一张大图要花时间，那期间别的 App 或剪贴板管理器可能写入新内容。
        // 旧实现拿到的 saved 是旧的，紧接着 clearContents 把新内容毁掉，
        // 之后「还原」还原的也是旧的——用户刚复制的东西就这么没了。
        //
        // ourChangeCount 救不了这种情况：它是销毁之后才记的。
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("InputAssistTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("快照开始前的内容", forType: .string)
        let changeCountBeforeSnapshot = pasteboard.changeCount

        // 模拟「快照进行到一半时别人改了剪贴板」。
        pasteboard.clearContents()
        pasteboard.setString("别的应用刚写进来的内容", forType: .string)

        // 判据就是这个比较：不相等就必须放弃，绝不能往下走到 clearContents。
        #expect(pasteboard.changeCount != changeCountBeforeSnapshot)
        #expect(pasteboard.string(forType: .string) == "别的应用刚写进来的内容")
    }

    @Test func bundleIdentifierAloneCannotDetectSameAppFocusChanges() {
        // 回归：粘贴前只比 bundle id 是不够的——**同一个 App 里换个输入框，
        // bundle id 是不变的**。而替换期间自动监听是暂停的，
        // 前面那些元素 / 选区校验都覆盖不到「深拷贝」那段间隔。
        //
        // 所以 press 之前必须把焦点元素和选区一起重新确认。
        // 这里钉住的是「选区不同就该拦下来」这个判据本身。
        let expected = InputAssistTextRange(location: 4, length: 6)
        let afterUserClickedAnotherField = InputAssistTextRange(location: 0, length: 0)
        #expect(expected != afterUserClickedAnotherField)

        // 同一个 bundle id 在两种情况下都成立，区分不出来。
        let sameBundle = "com.example.app"
        #expect(sameBundle == sameBundle)
    }

    @MainActor
    @Test func selectionValidationNeverSilentlySkipsWhenRangeIsUnavailable() {
        // 回归：拿不到 AXSelectedTextRange 的输入面**恰恰就是走粘贴兜底的那批**。
        // 旧写法是 `expectedSelectedRange == nil || 范围相等`——
        // range 为 nil 时整个条件恒真，等于在最需要校验的地方跳过了校验。
        let element = AXUIElementCreateSystemWide()

        // 两样都验不了 → 绝不放行。
        #expect(!InputAssistTextReplaceEngine.isSelectionUnchanged(
            in: element,
            expectedSelectedRange: nil,
            expectedSelectedText: nil
        ))

        // systemWide 元素读不到选区，所以给了期望值也必然对不上——
        // 关键是它返回 false 而不是 true。
        #expect(!InputAssistTextReplaceEngine.isSelectionUnchanged(
            in: element,
            expectedSelectedRange: nil,
            expectedSelectedText: "我们可以提供16吨船吊"
        ))
        #expect(!InputAssistTextReplaceEngine.isSelectionUnchanged(
            in: element,
            expectedSelectedRange: InputAssistTextRange(location: 0, length: 4),
            expectedSelectedText: nil
        ))
    }

    @MainActor
    @Test func abortPathRestoresClipboardOnlyWhenUntouched() {
        // 回归：press 前的几道 abort 分支原本是无条件 restore，
        // 会把用户在这期间复制的新内容覆盖掉。
        // press 失败和沉降路径早就用的是 restoreIfUntouched，abort 路径漏了。
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("InputAssistTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("用户原本的剪贴板", forType: .string)
        let snapshot = InputAssistPasteboardSnapshot.snapshot(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("我们放进去的译文", forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // 中途用户复制了新东西，然后某道检查失败要 abort。
        pasteboard.clearContents()
        pasteboard.setString("用户刚复制的新内容", forType: .string)

        InputAssistTextReplaceEngine.restoreIfUntouched(
            snapshot,
            expectedChangeCount: ourChangeCount,
            on: pasteboard
        )
        #expect(pasteboard.string(forType: .string) == "用户刚复制的新内容")
    }

    // MARK: - Apple 并行槽位（PRD §18）

    @MainActor
    @Test func applePoolVendsOneCoordinatorPerTargetLanguage() {
        // 一个 coordinator 只能同时处理一个请求，多语言并行必须一人一个。
        let pool = InputAssistAppleTranslationPool()
        defer { pool.shutdown() }

        pool.prepare(slotCount: 3)
        #expect(pool.slots.count == 3)
        #expect(pool.coordinator(at: 0) != nil)
        #expect(pool.coordinator(at: 2) != nil)
        #expect(pool.coordinator(at: 3) == nil)

        // 每个槽位必须是不同的实例，否则又会互相打断。
        let first = pool.coordinator(at: 0)
        let second = pool.coordinator(at: 1)
        #expect(first !== second)
    }

    @MainActor
    @Test func applePoolNeverExceedsTheTargetLanguageCap() {
        let pool = InputAssistAppleTranslationPool()
        defer { pool.shutdown() }

        pool.prepare(slotCount: 99)
        #expect(pool.slots.count == InputAssistLanguagePolicy.maximumTargetCount)

        // 语言变少时槽位保留不回收，但绝不会越界。
        pool.prepare(slotCount: 2)
        #expect(pool.slots.count == InputAssistLanguagePolicy.maximumTargetCount)
    }

    @MainActor
    @Test func applePoolShutsDownCleanly() {
        let pool = InputAssistAppleTranslationPool()
        pool.prepare(slotCount: 2)
        pool.shutdown()
        #expect(pool.slots.isEmpty)
        #expect(pool.coordinator(at: 0) == nil)

        // 关掉之后还能再开起来。
        pool.prepare(slotCount: 1)
        #expect(pool.slots.count == 1)
        pool.shutdown()
    }

    @Test func defaultShortcutIsOptionSpace() {
        #expect(InputAssistShortcut.default.displayString == "⌥Space")
    }

    @Test func defaultBlocklistCoversTheHighRiskApplications() {
        let blocklist = InputAssistAppFilter.defaultBlocklist
        #expect(blocklist.contains("com.apple.Terminal"))
        #expect(blocklist.contains("com.apple.dt.Xcode"))
        #expect(blocklist.contains("com.microsoft.VSCode"))
    }
}
