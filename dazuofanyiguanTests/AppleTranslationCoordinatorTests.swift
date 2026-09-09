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
                workerIsRunning: false,
                source: zhHans,
                target: english
            ) == .installNewConfiguration(
                TranslationSession.Configuration(source: zhHans, target: english)
            )
        )
    }

    @Test func samePairWithLiveWorkerReusesTheSession() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsRunning: true,
                source: zhHans,
                target: english
            ) == .reuseLiveSession(installed)
        )
    }

    @Test func samePairWithoutWorkerRerunsInstalledConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        let decision = AppleTranslationCoordinator.installationDecision(
            installed: installed,
            workerIsRunning: false,
            source: zhHans,
            target: english
        )

        var expectedRefreshed = installed
        expectedRefreshed.invalidate()
        #expect(decision == .rerunInstalledConfiguration(expectedRefreshed))
    }

    @Test func differentTargetLanguageInstallsNewConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsRunning: true,
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
                workerIsRunning: true,
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

        for (name, installedConfiguration, workerIsRunning, source, target) in scenarios {
            let decision = AppleTranslationCoordinator.installationDecision(
                installed: installedConfiguration,
                workerIsRunning: workerIsRunning,
                source: source,
                target: target
            )
            #expect(decision.configuration.source == source, "\(name)：绑定源语言不符")
            #expect(decision.configuration.target == target, "\(name)：绑定目标语言不符")
        }
    }
}
