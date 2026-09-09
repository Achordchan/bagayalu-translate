//
//  AppleTranslationCoordinatorTests.swift
//  dazuofanyiguanTests
//
//  Apple 本地翻译会话复用的回归测试。
//
//  背景：1.2.5 每次翻译都让 `.translationTask` 重跑一遍，为每个请求各建
//  一个 `TranslationSession` 且从不回收，系统翻译扩展因此陷入布局循环
//  （CPU 90%）。修复的核心是 `installationDecision` 的分岔：同语言对
//  绝不重建会话，只唤醒常驻 worker。
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
            ) == .installNewConfiguration
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
            ) == .reuseLiveSession
        )
    }

    @Test func samePairWithoutWorkerRerunsInstalledConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsRunning: false,
                source: zhHans,
                target: english
            ) == .rerunInstalledConfiguration
        )
    }

    @Test func differentTargetLanguageInstallsNewConfiguration() {
        let installed = TranslationSession.Configuration(source: zhHans, target: english)

        #expect(
            AppleTranslationCoordinator.installationDecision(
                installed: installed,
                workerIsRunning: true,
                source: zhHans,
                target: japanese
            ) == .installNewConfiguration
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
            ) == .installNewConfiguration
        )
    }
}
