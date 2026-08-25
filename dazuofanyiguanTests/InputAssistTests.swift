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

    // MARK: - 自动取词的去重（Codex review #5 第四轮）

    @MainActor
    @Test func aSelectionAlreadyHandledIsNotPickedUpAgain() {
        // Esc 关掉浮层时，key-down 被 CandidateKeyTap 吃掉，key-up 会漏到
        // 选区监听的全局监听器。如果这段选区没被记过，浮层会立刻自己弹回来。
        let monitor = InputAssistSelectionMonitor()
        let element = AXUIElementCreateSystemWide()
        func capture(_ text: String) -> InputAssistCapture {
            InputAssistCapture(
                element: element,
                sourceText: text,
                sourceRange: InputAssistTextRange(location: 0, length: text.utf16.count),
                elementValue: text,
                context: text,
                capability: .axDirect,
                role: "AXTextArea",
                allowsEditorPaste: true,
                anchorRect: .zero,
                hasPreciseCaretBounds: true,
                selectedRangeAtCapture: nil
            )
        }

        // 第一次是新选区。
        #expect(monitor.registerSelection(capture("hello")))
        // 同一段选区再来一次就该被跳过——这正是快捷键打开浮层后按 Esc 的情形。
        #expect(!monitor.registerSelection(capture("hello")))
        // 换了内容才算新选区。
        #expect(monitor.registerSelection(capture("world")))
    }

    // MARK: - 粘贴兜底的准入（Codex review #5 第二轮）

    @Test func unverifiableWriteMustNotBeFollowedByAPaste() {
        // AX 写调用已经发出去、但读不回结果时，无法证明它到底生效没有。
        // 这时再合成一次 ⌘V，万一那次写其实成功了，译文会被插入两遍。
        #expect(
            !InputAssistReplacementOutcome
                .aborted(reason: .writeVerificationUnavailable)
                .allowsPasteFallback
        )
    }

    @Test func clipboardContentionMustNotBeFollowedByACopy() {
        // 粘贴引擎遇到剪贴板争用时刻意不覆盖那份新内容。
        // 如果协调器接着走复制兜底，clearContents() 会把引擎特意保护的东西
        // 亲手毁掉——前脚保护后脚清掉，比一开始就不保护还糟。
        #expect(
            InputAssistReplacementOutcome
                .aborted(reason: .clipboardBusy)
                .preservesForeignClipboard
        )
        // 其余任何结果都不该挡掉复制兜底——译文拿不到才是更常见的损失。
        for reason in [
            InputAssistReplacementSafetyGuard.AbortReason.secureInputActive,
            .applicationChanged,
            .focusLost,
            .focusedElementChanged,
            .selectionChanged,
            .sourceTextChanged,
            .sourceRangeUnavailable,
            .writeVerificationUnavailable
        ] {
            #expect(
                !InputAssistReplacementOutcome
                    .aborted(reason: reason)
                    .preservesForeignClipboard,
                "\(reason.rawValue) 与剪贴板无关，不该挡掉复制兜底"
            )
        }
        #expect(
            !InputAssistReplacementOutcome
                .failed(message: "编辑器未接受译文替换")
                .preservesForeignClipboard
        )
    }

    @Test func everyOtherOutcomeStillAllowsThePasteFallback() {
        // 其余 abort 都发生在动手写**之前**（选区变了、焦点没了、应用切了…），
        // 没有任何文本被改过，兜底是安全的。
        for reason in [
            InputAssistReplacementSafetyGuard.AbortReason.secureInputActive,
            .applicationChanged,
            .focusLost,
            .focusedElementChanged,
            .selectionChanged,
            .sourceTextChanged,
            .sourceRangeUnavailable,
            .clipboardBusy
        ] {
            #expect(
                InputAssistReplacementOutcome.aborted(reason: reason).allowsPasteFallback,
                "\(reason.rawValue) 发生在写入之前，不该挡掉粘贴兜底"
            )
        }

        // .failed 是"读回来了、确认没生效"，正是最该走兜底的一类。
        #expect(
            InputAssistReplacementOutcome
                .failed(message: "当前应用拒绝了原位替换")
                .allowsPasteFallback
        )
        #expect(
            InputAssistReplacementOutcome
                .replaced(strategy: .axDirect)
                .allowsPasteFallback
        )
    }

    // MARK: - 含汉字的日韩文（Codex review #5）

    @Test func kanaDecidesJapaneseEvenWhenRecognitionAbstains() {
        // "私の" 只有两个 compact 字符，过不了 LanguageDetectionService 的字数门槛，
        // 识别器弃权返回 nil。但假名是决定性的——中文里不会出现它。
        // 要求 detected == "ja" 才保留日文，等于在识别器最不可靠的地方去依赖它。
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "私の",
                detectedLanguageCode: nil
            ) == "ja"
        )
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "한자漢字",
                detectedLanguageCode: nil
            ) == "ko"
        )
    }

    @Test func koreanWithHanjaIsNotFlattenedToChinese() {
        // 韩文里混着汉字（한자漢字）很常见。只看"有没有汉字"会把已经正确
        // 识别出来的韩文压成中文，候选请求的源语言就是错的，
        // 还会连带把错误的目标行过滤掉。
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "한자漢字",
                detectedLanguageCode: "ko"
            ) == "ko"
        )
    }

    @Test func japaneseWithKanjiStillKeepsJapanese() {
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "日本語の漢字",
                detectedLanguageCode: "ja"
            ) == "ja"
        )
        // 半角片假名也算假名——共享的 TextScriptPresence 比原来那份私有实现多覆盖这一段。
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "漢字ｶﾀｶﾅ",
                detectedLanguageCode: "ja"
            ) == "ja"
        )
    }

    @Test func chineseTextStillOverridesAWrongDetection() {
        // 这条是这个函数原本要解决的问题，不能因为上面两条被破坏：
        // 中英混排 / 数字型号会让识别器返回非中文，那时仍然按中文处理。
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "这是 iPhone 15 Pro 的说明",
                detectedLanguageCode: "en"
            ) == "zh-CN"
        )
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "纯中文",
                detectedLanguageCode: nil
            ) == "zh-CN"
        )
        // 没有汉字时原样放行。
        #expect(
            InputAssistLanguagePolicy.selectionSourceLanguageCode(
                for: "hello",
                detectedLanguageCode: "en"
            ) == "en"
        )
    }

    // MARK: - Chromium / Electron 取词

    @MainActor
    @Test func aTransientFailureIsNeverCachedAsAConclusion() {
        // 这条是要害：把 .cannotComplete（目标应用正忙 / 刚启动）当成永久结论，
        // 等于把那个应用永久废掉——直到它或翻译官重启才会再试一次。
        #expect(
            InputAssistChromiumAccessibility.classify(.cannotComplete) == .transientFailure
        )
        #expect(
            InputAssistChromiumAccessibility.classify(.apiDisabled) == .transientFailure
        )
        #expect(
            InputAssistChromiumAccessibility.classify(.invalidUIElement) == .transientFailure
        )
        #expect(InputAssistChromiumAccessibility.classify(.failure) == .transientFailure)

        // 只有这两类是真的"再试也一样"。
        #expect(
            InputAssistChromiumAccessibility.classify(.attributeUnsupported)
                == .permanentlyUnsupported
        )
        #expect(
            InputAssistChromiumAccessibility.classify(.notImplemented) == .permanentlyUnsupported
        )

        #expect(InputAssistChromiumAccessibility.classify(.success) == .enabled)
    }

    @MainActor
    @Test func enablingIsNeverAnnouncedTwiceForTheSameProcess() {
        // 打开别人进程的 AX 树是有开销的，同一个应用不该反复去设。
        // （本进程不是 Chromium，实际返回哪种错误由系统决定，
        // 所以这里只断言与错误类型无关的那个不变式。）
        InputAssistChromiumAccessibility.reset()
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = InputAssistChromiumAccessibility.enableIfNeeded(pid: pid)
        let second = InputAssistChromiumAccessibility.enableIfNeeded(pid: pid)
        #expect(!(first && second))
        if first {
            #expect(InputAssistChromiumAccessibility.hasSettledResult(pid: pid))
        }
        InputAssistChromiumAccessibility.reset()
        #expect(!InputAssistChromiumAccessibility.hasSettledResult(pid: pid))
    }

    @MainActor
    @Test func aTerminatedProcessLosesItsCachedConclusion() {
        // macOS 会回收 pid，而翻译官是常驻的。被缓存的应用退出后，
        // 新启动的 Chromium 应用可能拿到同一个 pid——如果记录还在，
        // AXManualAccessibility 再也不会写下去，那个进程的取词就永久不可用了。
        InputAssistChromiumAccessibility.reset()
        let pid = ProcessInfo.processInfo.processIdentifier

        let announced = InputAssistChromiumAccessibility.enableIfNeeded(pid: pid)
        if announced || InputAssistChromiumAccessibility.hasSettledResult(pid: pid) {
            #expect(InputAssistChromiumAccessibility.hasSettledResult(pid: pid))
            InputAssistChromiumAccessibility.evict(pid: pid)
            #expect(!InputAssistChromiumAccessibility.hasSettledResult(pid: pid))
        }

        // 驱逐一个从没记过的 pid 不该出问题。
        InputAssistChromiumAccessibility.evict(pid: 999_999)
        InputAssistChromiumAccessibility.reset()
    }

    @MainActor
    @Test func invalidProcessIdentifierIsNeverTouched() {
        InputAssistChromiumAccessibility.reset()
        #expect(!InputAssistChromiumAccessibility.enableIfNeeded(pid: 0))
        #expect(!InputAssistChromiumAccessibility.enableIfNeeded(pid: -1))
    }

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

    @Test func copyOnlyModeReservesSpaceForTheCapabilityNotice() {
        let replace = CandidatePanelLayout.panelSize(
            rowCount: 2,
            selectedIndex: 0,
            reservedLineCount: 1,
            showsDebugInfo: false,
            showsCopyNotice: false
        )
        let copy = CandidatePanelLayout.panelSize(
            rowCount: 2,
            selectedIndex: 0,
            reservedLineCount: 1,
            showsDebugInfo: false,
            showsCopyNotice: true
        )
        #expect(copy.height == replace.height + CandidatePanelLayout.copyNoticeHeight)
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

    // MARK: - 选区源语言

    @Test func selectedHanTextKeepsAChineseSourceAcrossLongPunctuatedText() {
        let text = "您好！关于您昨天询问的设备，我们可以提供16吨船吊；如果需要技术参数、价格和交货周期，请随时联系我们。"

        #expect(InputAssistLanguagePolicy.selectionSourceLanguageCode(
            for: text,
            detectedLanguageCode: nil
        ) == "zh-CN")
        #expect(InputAssistLanguagePolicy.selectionSourceLanguageCode(
            for: text,
            detectedLanguageCode: "fr"
        ) == "zh-CN")
        #expect(InputAssistLanguagePolicy.selectionSourceLanguageCode(
            for: text,
            detectedLanguageCode: "zh-TW"
        ) == "zh-TW")
    }

    @Test func selectedJapaneseTextWithKanaKeepsJapaneseDetection() {
        #expect(InputAssistLanguagePolicy.selectionSourceLanguageCode(
            for: "昨日の設備について、詳細を送ってください。",
            detectedLanguageCode: "ja"
        ) == "ja")
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
        #expect(coordinator.lastStatusMessage == "需要辅助功能权限才能读取和替换选中文本")
        #expect(!coordinator.hotkeyStatus.isActive)

        // 用户在系统设置里授权，切回 App。
        isTrusted = true
        coordinator.reapplyEnabledStateIfPermissionArrived()

        // 快捷键有没有真的抢到手要看运行环境（可能被别的 App 占了），
        // 但「还在提示缺权限」这件事必须消失——那正是这条 bug 的表征。
        #expect(coordinator.lastStatusMessage != "需要辅助功能权限才能读取和替换选中文本")
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
    @Test func selectionAutoShowIsExplicitAndDefaultsOff() throws {
        let suiteName = "InputAssistTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = InputAssistSettings(defaults: defaults)
        #expect(!settings.isSelectionAutoShowEnabled)
        settings.isSelectionAutoShowEnabled = true
        #expect(settings.isSelectionAutoShowEnabled)
        #expect(InputAssistSelectionMonitor.settleNanoseconds == 180_000_000)
    }

    @Test func commitPolicyUsesAXThenEditablePasteThenCopy() {
        #expect(InputAssistCommitPolicy.mode(
            capability: .axDirect,
            allowsEditorPaste: true,
            hasSourceRange: true,
            hasElementValue: true
        ) == .axReplace)

        #expect(InputAssistCommitPolicy.mode(
            capability: .copyOnly,
            allowsEditorPaste: true,
            hasSourceRange: false,
            hasElementValue: false
        ) == .editorPaste)

        #expect(InputAssistCommitPolicy.mode(
            capability: .copyOnly,
            allowsEditorPaste: false,
            hasSourceRange: false,
            hasElementValue: false
        ) == .copy)

    }

    @MainActor
    @Test func editorPasteRestoreNeverOverwritesANewerClipboardValue() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("InputAssistTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("原剪贴板", forType: .string)
        let snapshot = InputAssistPasteboardSnapshot.snapshot(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("译文", forType: .string)
        let translationChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("用户刚复制的新内容", forType: .string)
        InputAssistEditorPasteEngine.restoreIfUntouched(
            snapshot,
            expectedChangeCount: translationChangeCount,
            pasteboard: pasteboard
        )
        #expect(pasteboard.string(forType: .string) == "用户刚复制的新内容")
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
        // 快捷键被其它 App 占用时，设置页必须能更换。
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
            allowsEditorPaste: true,
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
        #expect(session.allowsEditorPaste)
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

    @Test func bareDomainUrlsAreNotTranslatable() {
        // 回归：`example.com/产品` 既不带 http:// 前缀也不含 ://，旧实现判不出是 URL。
        // 而它路径里带中文，选中整条 URL 时也不应当成普通文本翻译。
        for url in [
            "example.com/产品",
            "example.com",
            "shop.example.co/列表",
            "my-site.cn/关于我们"
        ] {
            #expect(InputAssistSentenceBoundary.looksLikeURL(url), "\(url) 应当被识别为 URL")
            #expect(!InputAssistSentenceBoundary.looksTranslatable(url), "\(url) 不该可翻译")
        }
    }

    @Test func bareDomainDetectionDoesNotSwallowOrdinaryText() {
        // 别把上一条修过头了。
        for text in [
            "12.5",                      // 小数
            "我们提供16吨船吊.价格面议",   // 顶级域不是 ASCII 字母
            "我们可以提供16吨船吊",        // 压根没有点
            "总价 12.5 万美元"            // 有空格，不是单 token
        ] {
            #expect(
                !InputAssistSentenceBoundary.looksLikeBareDomain(text),
                "\(text) 不该被当成域名"
            )
        }
        #expect(InputAssistSentenceBoundary.looksTranslatable("我们提供16吨船吊.价格面议"))
    }

    @MainActor
    @Test func targetValidationCoversAppFocusAndSelectionTogether() {
        // 回归：AX 写之前也要重新确认——`isSettable` 是跨进程查询，
        // 目标 App 忙的时候能卡上好几秒，之前那次校验早就过期了。
        //
        // 三样任意一样对不上都要给出对应的 abort 原因，而不是笼统地报一个。
        let element = AXUIElementCreateSystemWide()

        // 前台 App 对不上 → applicationChanged（最先短路）。
        #expect(InputAssistTextReplaceEngine.invalidTargetReason(
            element: element,
            expectedSelectedRange: nil,
            expectedSelectedText: "好的",
            expectedBundleIdentifier: "com.example.definitely-not-frontmost"
        ) == .applicationChanged)
    }

    @Test func bareDomainStripsQueryFragmentAndPort() {
        // 回归：只按 `/` 截主机名的话，`example.com?关键词` 的顶级域会变成
        // `com?关键词`，ASCII 字母校验失败 → 判不出是 URL → 又漏回自动翻译那条路。
        for url in [
            "example.com?关键词",
            "example.com#说明",
            "example.com:8080/产品",
            "shop.example.co:443?q=中文"
        ] {
            #expect(InputAssistSentenceBoundary.looksLikeBareDomain(url), "\(url) 应识别为域名")
            #expect(!InputAssistSentenceBoundary.looksTranslatable(url), "\(url) 不该可翻译")
        }
    }

    // 这一组直接调用生产判定函数。
    // 之前那两条只断言枚举 rawValue 和 NSPasteboard 自身的行为——
    // 把三态分支删掉、把 .unverifiable 重新接回粘贴兜底，它们照样全绿，
    // 等于对本轮真正修的行为没有任何防护。

    @Test func readBackFailureIsUnverifiable() {
        // 回归：AX 写返回 .success 之后读不回 kAXValue（目标 App 忙 / 超时 / 瞬时错误）。
        // 写很可能已经生效、选区已经塌缩，这时再粘贴就是把译文插进去第二遍。
        let verification = InputAssistTextReplaceEngine.WriteVerification.classify(
            valueAfterWrite: nil,
            valueBeforeWrite: "前面我们可以提供后面",
            expectedValueAfterWrite: "前面We can provide后面"
        )
        #expect(verification == .unverifiable)
    }

    @Test func onlyTheExactExpectedValueCountsAsASuccessfulWrite() {
        let before = "前面我们可以提供后面"
        let expected = "前面We can provide后面"

        #expect(InputAssistTextReplaceEngine.WriteVerification.classify(
            valueAfterWrite: expected,
            valueBeforeWrite: before,
            expectedValueAfterWrite: expected
        ) == .applied)

        // 一个字都没变 = 目标 App 忽略了这次原位写入。
        let ignored = InputAssistTextReplaceEngine.WriteVerification.classify(
            valueAfterWrite: before,
            valueBeforeWrite: before,
            expectedValueAfterWrite: expected
        )
        #expect(ignored == .didNotApply)
    }

    @Test func aThirdStateMustNotBeMistakenForSuccess() {
        // 关键回归：「和写之前不一样」**不能**当成功判据。
        // 读回失败后我们还会等 30ms 重试，这期间用户输入、宿主自动更正、异步编辑，
        // 任何一样让全文变了，弱判据都会误报成功——哪怕 AX 写其实被忽略、或只写进去一半。
        let before = "前面我们可以提供后面"
        let expected = "前面We can provide后面"

        for actual in [
            "前面我们可以提供后面X",        // 用户在这期间又打了一个字
            "前面We can provide",          // 只写进去一半
            "前面WE CAN PROVIDE后面"       // 宿主自动更正改写了
        ] {
            let verification = InputAssistTextReplaceEngine.WriteVerification.classify(
                valueAfterWrite: actual,
                valueBeforeWrite: before,
                expectedValueAfterWrite: expected
            )
            #expect(verification == .unverifiable, "\(actual) 不该被判成写入成功")
        }
    }

    @Test func staleBeforeOnTheFirstReadMustNotAuthorizePaste() {
        // 回归：有的 App 是异步落地的——写下去之后立刻读，还是写之前的样子。
        // 只凭这一次就判 .didNotApply 并马上补 ⌘V，
        // 等原来那次 AX 写随后落地，译文就出现了两遍。
        //
        // 只有连续两次都精确读到「和写之前一模一样」，才敢放行粘贴。
        typealias Verification = InputAssistTextReplaceEngine.WriteVerification

        // 第一次读到 before、第二次才看到期望值 → 是异步生效，成功，绝不能粘贴。
        #expect(Verification.resolve(first: .didNotApply, second: .applied) == .applied)

        // 两次都是 before → 确实没生效。
        let stable = Verification.resolve(first: .didNotApply, second: .didNotApply)
        #expect(stable == .didNotApply)

        // 只要有一次读不到 / 是第三种样子，就不许粘贴。
        for pair in [
            (Verification.didNotApply, Verification.unverifiable),
            (Verification.unverifiable, Verification.didNotApply),
            (Verification.unverifiable, Verification.unverifiable)
        ] {
            let resolved = Verification.resolve(first: pair.0, second: pair.1)
            #expect(resolved == .unverifiable, "\(pair)")
        }
    }

    @Test func aSuccessfulFirstReadShortCircuitsWithoutWaiting() {
        typealias Verification = InputAssistTextReplaceEngine.WriteVerification
        #expect(Verification.resolve(first: .applied, second: .unverifiable) == .applied)
        #expect(Verification.resolve(first: .applied, second: .didNotApply) == .applied)
    }

    @Test func expectedValueAfterWriteIsSplicedByUTF16Range() {
        let text = "前面内容我们可以提供后面"
        let range = InputAssistTextRange(location: 4, length: 6)
        #expect(InputAssistAXTextCapture.replacingRange(
            in: text,
            range: range,
            with: "We can provide"
        ) == "前面内容We can provide后面")

        // 越界或切在代理对中间 → 算不出期望值，就不该动手写。
        #expect(InputAssistAXTextCapture.replacingRange(
            in: text,
            range: InputAssistTextRange(location: 0, length: 999),
            with: "x"
        ) == nil)
        #expect(InputAssistAXTextCapture.replacingRange(
            in: "报价👍好的",
            range: InputAssistTextRange(location: 2, length: 1),
            with: "x"
        ) == nil)
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

    @Test func defaultShortcutAvoidsTheGeminiOptionSpaceConflict() {
        #expect(InputAssistShortcut.default.displayString == "⌥⇧Space")
    }

    @Test func defaultBlocklistCoversTheHighRiskApplications() {
        let blocklist = InputAssistAppFilter.defaultBlocklist
        #expect(blocklist.contains("com.apple.Terminal"))
        #expect(blocklist.contains("com.1password.1password"))
        #expect(!blocklist.contains("com.apple.dt.Xcode"))
        #expect(!blocklist.contains("com.microsoft.VSCode"))
    }
}
