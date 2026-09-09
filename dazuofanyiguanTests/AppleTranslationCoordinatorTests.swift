//
//  AppleTranslationCoordinatorTests.swift
//  dazuofanyiguanTests
//
//  Apple 本地翻译会话复用的回归测试。
//
//  背景：1.2.5 每次翻译都让 `.translationTask` 重跑一遍，为每个请求各建
//  一个 `TranslationSession` 且从不回收，系统翻译扩展因此陷入布局循环
//  （CPU 90%）。修复的核心是 `installationDecision` 的分岔：同语言对
//  绝不重建会话，只唤醒常驻 worker；请求与 worker 各自绑定 Configuration，
//  服务前校验一致，防止旧语言对的 worker 串台服务新请求。
//

import Foundation
import Testing
import Translation
@testable import 大佐翻译官v1

@Suite("Apple 翻译会话复用")
struct AppleTranslationCoordinatorTests {
    private let zhHans = Locale.Language(identifier: "zh-Hans")
    private let english = Locale.Language(identifier: "en")
    private let japanese = Locale.Language(identifier: "ja")

    @Test func firstRequestInstallsNewConfiguration() {
        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: nil,
                workerIsIdle: false,
                source: zhHans,
                target: english
            ) == .installNewConfiguration(
                TranslationSession.Configuration(source: zhHans, target: english)
            )
        )
    }

    @Test func samePairWithIdleWorkerReusesTheSession() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsIdle: true,
                source: zhHans,
                target: english
            ) == .reuseLiveSession(installed)
        )
    }

    @Test func samePairWithoutWorkerRerunsInstalledConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        let decision = AppleTranslationCoordinator.installationDecision(
            installed: installed,
            workerIsIdle: false,
            source: zhHans,
            target: english
        )

        var expectedRefreshed = installed
        expectedRefreshed.invalidate()
        #expect(decision == .rerunInstalledConfiguration(expectedRefreshed))
    }

    /// 评审第三轮指出的阻塞回归：同语言对顶替一个**在途**请求时不能只排队
    /// 唤醒——卡住的 `prepareTranslation()`/`translate()` 会把后续请求全部
    /// 堵死。必须走重跑路径发布 invalidate 配置，让 SwiftUI 取消旧任务、
    /// 打断在途翻译。且重跑值必须不同于已安装值（invalidate 不幂等，已实测），
    /// 否则任务不会重启、打断不会发生。
    @Test func busyWorkerIsInterruptedInsteadOfQueueingBehindInFlightWork() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        guard case .rerunInstalledConfiguration(let refreshed)? = Optional(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsIdle: false,
                source: zhHans,
                target: english
            )
        ) else {
            Issue.record("忙时顶替必须走重跑路径")
            return
        }
        #expect(refreshed != installed, "重跑发布值必须不同于已安装值，任务才会重启")
        #expect(refreshed.source == installed.source)
        #expect(refreshed.target == installed.target)
    }

    /// 连续两次忙时顶替（中间没有别的发布）都必须能触发重启：
    /// 对上一次的重跑值再 invalidate 依然产生新值。
    @Test func consecutiveRerunsAlwaysChangeThePublishedValue() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        var previous = installed
        for round in 1...3 {
            guard case .rerunInstalledConfiguration(let refreshed)? = Optional(
                AppleTranslationCoordinator.installationDecision(
                    installed: previous,
                    workerIsIdle: false,
                    source: zhHans,
                    target: english
                )
            ) else {
                Issue.record("第 \(round) 轮重跑决策异常")
                return
            }
            #expect(refreshed != previous, "第 \(round) 轮重跑值必须不同于上一轮")
            previous = refreshed
        }
    }

    @Test func differentTargetLanguageInstallsNewConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsIdle: true,
                source: zhHans,
                target: japanese
            ) == .installNewConfiguration(
                TranslationSession.Configuration(source: zhHans, target: japanese)
            )
        )
    }

    @Test func differentSourceLanguageInstallsNewConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsIdle: true,
                source: nil,
                target: english
            ) == .installNewConfiguration(
                TranslationSession.Configuration(source: nil, target: english)
            )
        )
    }

    /// 无论哪条分支，请求绑定的 Configuration 必须携带**本次请求**的语言对。
    /// 这是 worker 服务前校验能防串台的前提：语言对切换后，旧 worker 手里的
    /// 旧配置和新请求的绑定不一致，会被直接跳过。
    @Test func everyDecisionBindsTheRequestToTheRequestedPair() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        let scenarios: [(String, TranslationSession.Configuration?, Bool, Locale.Language?, Locale.Language)] = [
            ("首次安装", nil, false, zhHans, english),
            ("同对复用", installed, true, zhHans, english),
            ("同对重跑", installed, false, zhHans, english),
            ("目标语变化", installed, true, zhHans, japanese),
            ("源语变化", installed, true, nil, english)
        ]

        for (name, installedConfiguration, workerIsIdle, source, target) in scenarios {
            let decision = AppleTranslationCoordinator.installationDecision(
                installed: installedConfiguration,
                workerIsIdle: workerIsIdle,
                source: source,
                target: target
            )
            #expect(decision.configuration.source == source, "\(name)：绑定源语言不符")
            #expect(decision.configuration.target == target, "\(name)：绑定目标语言不符")
        }
    }

    // MARK: - worker 退出自救的重绑（语言对切换竞态）

    /// 评审第二三轮指出的挂死路径：语言对切换取消旧 worker、新请求挂在
    /// 新配置上时，自救 invalidate 发布的刷新值与请求的旧绑定**不再相等**
    /// （`Configuration.==` 含 invalidated 状态），若不把请求一并重绑，
    /// 新 worker 的校验永远不过，请求无限等待。这里固化「刷新值必然不同于
    /// 旧绑定」的前提，以及绑定与发布必须落同一个值。
    @Test func rescueRebindsWhenRequestMatchesInstalledConfiguration() {
        let japaneseConfiguration = TranslationSession.Configuration(source: zhHans, target: japanese)

        let refreshed = AppleTranslationCoordinator.rescueBinding(
            requestConfiguration: japaneseConfiguration,
            installedConfiguration: japaneseConfiguration
        )

        #expect(refreshed != nil)
        // 不重绑就会挂死的直接证据：刷新值与旧绑定不相等。
        #expect(refreshed != japaneseConfiguration)
        // 刷新值就是安装配置的 invalidate 副本：发布目标与重绑目标是
        // 同一个值（调用方把返回值同时写进 pendingRequest.configuration
        // 和 sessionConfiguration）。
        var expectedRefreshed = japaneseConfiguration
        expectedRefreshed.invalidate()
        #expect(refreshed == expectedRefreshed)
    }

    /// 请求绑定与当前安装的配置不一致（语言对切换的残留）时，自救必须
    /// 拒绝插手——那种请求由切换触发的新任务接手。
    @Test func rescueDeclinesWhenBindingDivergesFromInstalledConfiguration() {
        let englishConfiguration = TranslationSession.Configuration(source: zhHans, target: english)
        let japaneseConfiguration = TranslationSession.Configuration(source: zhHans, target: japanese)

        #expect(
            AppleTranslationCoordinator.rescueBinding(
                requestConfiguration: englishConfiguration,
                installedConfiguration: japaneseConfiguration
            ) == nil
        )
    }

    @Test func rescueDeclinesWithoutRequestOrInstalledConfiguration() {
        let configuration = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.rescueBinding(
                requestConfiguration: nil,
                installedConfiguration: configuration
            ) == nil
        )
        #expect(
            AppleTranslationCoordinator.rescueBinding(
                requestConfiguration: configuration,
                installedConfiguration: nil
            ) == nil
        )
    }
}
