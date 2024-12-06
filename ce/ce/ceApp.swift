//
//  ceApp.swift
//  ce
//
//  Created by A chord on 2024/12/2.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let themeSettings = ThemeSettings()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 应用保存的主题设置
        themeSettings.applyTheme()
        
        // 设置窗口代理
        if let window = NSApplication.shared.windows.first {
            window.delegate = self
        }
        
        // 创建状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // 使用应用程序图标
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                let resizedIcon = NSImage(size: NSSize(width: 18, height: 18))
                resizedIcon.lockFocus()
                appIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
                resizedIcon.unlockFocus()
                button.image = resizedIcon
            }
        }
        
        // 创建菜单
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示窗口", action: #selector(showApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc func showApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            window.deminiaturize(nil)
        }
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 阻止窗口关闭，改为最小化
        sender.miniaturize(nil)
        return false
    }
}

@main
struct ceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .frame(width: 900, height: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
    }
}
