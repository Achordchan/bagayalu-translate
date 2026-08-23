//
//  dazuofanyiguanApp.swift
//  dazuofanyiguan
//
//  Created by AchordChan on 2025/12/19.
//

import AppKit
import SwiftUI

@main
struct dazuofanyiguanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings: AppSettings
    @StateObject private var updater = AppUpdaterController()
    @StateObject private var toast = ToastCenter()
    @StateObject private var log = LogStore()
    @StateObject private var windowController = AppWindowController()
    @StateObject private var clipboardMonitor = ClipboardDoubleCopyMonitor()
    @StateObject private var hotkeyMonitor = GlobalHotkeyMonitor()
    @StateObject private var miniTranslationController = MiniTranslationController()
    @StateObject private var appleTranslationCoordinator: AppleTranslationCoordinator
    @StateObject private var translatorVM: TranslatorViewModel
    @StateObject private var screenshotOCR: ScreenshotOCRCoordinator
    @StateObject private var inputAssistSettings: InputAssistSettings
    @StateObject private var inputAssistCoordinator: InputAssistCoordinator

    init() {
        LegacySandboxPreferencesMigration.migrateIfNeeded()

        let mainAppleTranslationCoordinator = AppleTranslationCoordinator()
        let screenshotAppleTranslationCoordinator = AppleTranslationCoordinator()

        _settings = StateObject(wrappedValue: AppSettings())
        _appleTranslationCoordinator = StateObject(wrappedValue: mainAppleTranslationCoordinator)
        _translatorVM = StateObject(
            wrappedValue: TranslatorViewModel(
                appleTranslationCoordinator: mainAppleTranslationCoordinator
            )
        )
        _screenshotOCR = StateObject(
            wrappedValue: ScreenshotOCRCoordinator(
                appleTranslationCoordinator: screenshotAppleTranslationCoordinator
            )
        )

        let inputAssistSettings = InputAssistSettings()
        _inputAssistSettings = StateObject(wrappedValue: inputAssistSettings)
        _inputAssistCoordinator = StateObject(
            wrappedValue: InputAssistCoordinator(settings: inputAssistSettings)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .appleTranslationSession(using: appleTranslationCoordinator)
                .preferredColorScheme(settings.appearance.colorScheme)
                .toastHost()
                .environmentObject(settings)
                .environmentObject(toast)
                .environmentObject(log)
                .environment(\.logStore, log)
                .environmentObject(windowController)
                .environmentObject(clipboardMonitor)
                .environmentObject(hotkeyMonitor)
                .environmentObject(miniTranslationController)
                .environmentObject(appleTranslationCoordinator)
                .environmentObject(translatorVM)
                .environmentObject(screenshotOCR)
                .environmentObject(inputAssistSettings)
                .environmentObject(inputAssistCoordinator)
                .onAppear {
                    inputAssistCoordinator.activate(
                        appSettings: settings,
                        log: log,
                        toast: toast
                    )
                }
        }
        .defaultSize(
            width: AppWindowController.preferredContentSize.width,
            height: AppWindowController.preferredContentSize.height
        )
        .commands {
            AppCommands(updater: updater)
        }

        Settings {
            SettingsView()
                .preferredColorScheme(settings.appearance.colorScheme)
                .environmentObject(settings)
                .environmentObject(log)
                .environment(\.logStore, log)
                .environmentObject(hotkeyMonitor)
                .environmentObject(updater)
                .environmentObject(inputAssistSettings)
                .environmentObject(inputAssistCoordinator)
                .inputAssistTestWindowOpener()
        }

        Window("控制台", id: "console") {
            LogConsoleView()
                .environmentObject(log)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        Window("输入增强测试", id: "inputAssistTest") {
            InputAssistTestView(
                settings: inputAssistSettings,
                coordinator: inputAssistCoordinator
            )
            .preferredColorScheme(settings.appearance.colorScheme)
        }

        MenuBarExtra("大佐翻译官", systemImage: "character.bubble") {
            Toggle("Mini 模式", isOn: $settings.miniModeEnabled)

            Toggle("输入增强", isOn: Binding(
                get: { inputAssistSettings.isEnabled },
                set: { newValue in
                    inputAssistSettings.isEnabled = newValue
                    inputAssistCoordinator.applyEnabledState()
                }
            ))

            Divider()

            Button("显示主窗口") {
                windowController.showAndActivate()
            }

            Button("退出大佐翻译官") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct AppCommands: Commands {
    @ObservedObject var updater: AppUpdaterController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于大佐翻译官") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }

            Button("检查更新…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .appTermination) {
            Button("退出大佐翻译官") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        CommandGroup(replacing: .textEditing) {
            Button("剪切") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x")

            Button("复制") {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("c")

            Button("粘贴") {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v")

            Divider()

            Button("全选") {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("a")
        }

        CommandMenu("翻译") {
            Button("显示主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    window.deminiaturize(nil)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut("0")

            Divider()

            Button("立即翻译") {
                NotificationCenter.default.post(name: .dazuofanyiguanTranslateNow, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [.command])

            Button("清空原文") {
                NotificationCenter.default.post(name: .dazuofanyiguanClearInput, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: [.command])

            Button("复制译文") {
                NotificationCenter.default.post(name: .dazuofanyiguanCopyOutput, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let dazuofanyiguanTranslateNow = Notification.Name("dazuofanyiguan.translateNow")
    static let dazuofanyiguanClearInput = Notification.Name("dazuofanyiguan.clearInput")
    static let dazuofanyiguanCopyOutput = Notification.Name("dazuofanyiguan.copyOutput")
    static let dazuofanyiguanOpenPermissionGuide = Notification.Name("dazuofanyiguan.openPermissionGuide")
    static let dazuofanyiguanOpenInputAssistTest = Notification.Name("dazuofanyiguan.openInputAssistTest")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
