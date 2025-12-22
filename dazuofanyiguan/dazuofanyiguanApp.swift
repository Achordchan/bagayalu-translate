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

    @StateObject private var settings = AppSettings()
    @StateObject private var toast = ToastCenter()
    @StateObject private var log = LogStore()
    @StateObject private var windowController = AppWindowController()
    @StateObject private var clipboardMonitor = ClipboardDoubleCopyMonitor()
    @StateObject private var hotkeyMonitor = GlobalHotkeyMonitor()
    @StateObject private var translatorVM = TranslatorViewModel()
    @StateObject private var screenshotOCR = ScreenshotOCRCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.appearance.colorScheme)
                .toastHost()
                .environmentObject(settings)
                .environmentObject(toast)
                .environmentObject(log)
                .environmentObject(windowController)
                .environmentObject(clipboardMonitor)
                .environmentObject(hotkeyMonitor)
                .environmentObject(translatorVM)
                .environmentObject(screenshotOCR)
        }
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
                .preferredColorScheme(settings.appearance.colorScheme)
                .environmentObject(settings)
                .environmentObject(log)
                .environmentObject(hotkeyMonitor)
        }

        Window("控制台", id: "console") {
            LogConsoleView()
                .environmentObject(log)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于大佐翻译官") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "大佐翻译官")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出大佐翻译官", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        item.menu = menu
        statusItem = item
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @objc
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier == AppWindowController.mainWindowIdentifier }) ?? NSApp.windows.first {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }
}
