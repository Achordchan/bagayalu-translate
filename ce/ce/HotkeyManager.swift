import Foundation
import Carbon
import AppKit
import Combine
import os.log

class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()
    private var translationCallback: (() -> Void)?
    private var lastCommandCTime: TimeInterval = 0
    private var isFirstC = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionCheckTimer: Timer?
    private var lastPermissionCheck: TimeInterval = 0
    private let permissionCheckInterval: TimeInterval = 5 // 每5秒检查一次
    
    @Published private(set) var hasAccessibilityPermission = false {
        didSet {
            if hasAccessibilityPermission {
                setupGlobalMonitor()
            } else {
                disableMonitor()
            }
        }
    }
    
    private init() {
        print("HotkeyManager 初始化")
        hasAccessibilityPermission = checkAccessibilityPermission()
        if hasAccessibilityPermission {
            setupGlobalMonitor()
        }
        
        // 启动定时器检查权限状态
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: permissionCheckInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentTime = Date().timeIntervalSince1970
            
            // 只有在距离上次检查超过指定间隔时才进行检查
            if currentTime - self.lastPermissionCheck >= self.permissionCheckInterval {
                let currentPermission = self.checkAccessibilityPermission()
                if currentPermission != self.hasAccessibilityPermission {
                    print("权限状态变化：\(currentPermission)")
                    DispatchQueue.main.async {
                        self.hasAccessibilityPermission = currentPermission
                    }
                }
                self.lastPermissionCheck = currentTime
            }
        }
    }
    
    private func checkAccessibilityPermission() -> Bool {
        // 检查进程是否被信任
        let trusted = AXIsProcessTrusted()
        
        // 只在权限状态改变时才打印日志
        if trusted != hasAccessibilityPermission {
            print("权限状态变化: \(trusted)")
            let bundlePath = Bundle.main.bundlePath
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "未知"
            print("应用程序路径: \(bundlePath)")
            print("应用程序标识符: \(bundleIdentifier)")
        }
        
        return trusted
    }
    
    func requestAccessibilityPermission() {
        print("请求权限")
        
        // 获取应用程序的路径
        let appPath = Bundle.main.bundlePath
        print("正在请求权限的应用程序路径: \(appPath)")
        
        // 尝试通过 NSWorkspace 打开应用程序所在的文件夹
        NSWorkspace.shared.selectFile(appPath, inFileViewerRootedAtPath: "")
        
        // 首先尝试通过系统对话框请求权限
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("权限请求结果: \(trusted)")
        
        if !trusted {
            print("尝试打开系统偏好设置")
            DispatchQueue.main.async {
                // 尝试打开系统偏好设置的辅助功能面板
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                    
                    // 显示提示信息
                    let alert = NSAlert()
                    alert.messageText = "需要辅助功能权限"
                    alert.informativeText = "请在系统设置中找到应用程序，并勾选复选框以启用辅助功能权限。\n\n如果在列表中找不到应用程序，请将应用程序从 Finder 中拖到列表中。"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "好的")
                    
                    alert.runModal()
                }
            }
        }
    }
    
    private func disableMonitor() {
        print("禁用监听器")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
    }
    
    private func setupGlobalMonitor() {
        print("设置全局监听器")
        
        // 清理现有的监听器
        disableMonitor()
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            
            switch CGEventType(rawValue: type.rawValue)! {
            case .flagsChanged:
                // 检测 Command 键状态
                let flags = event.flags
                let isCommandPressed = flags.contains(.maskCommand)
                
                if !isCommandPressed {
                    manager.isFirstC = false
                    manager.lastCommandCTime = 0
                }
                
            case .keyDown:
                // 检测 C 键
                if event.flags.contains(.maskCommand) && event.getIntegerValueField(.keyboardEventKeycode) == 8 {
                    let currentTime = Date().timeIntervalSince1970
                    
                    if !manager.isFirstC {
                        // 第一次按 C，让系统处理复制操作
                        manager.isFirstC = true
                        manager.lastCommandCTime = currentTime
                        return Unmanaged.passRetained(event)
                    } else {
                        // 第二次按 C，检查时间间隔
                        if currentTime - manager.lastCommandCTime < 0.5 {
                            print("检测到全局连续的 Command+C，触发翻译")
                            DispatchQueue.main.async {
                                manager.handleTranslation()
                            }
                            manager.isFirstC = false
                            manager.lastCommandCTime = 0
                            return nil // 阻止事件继续传播
                        } else {
                            // 时间间隔太长，视为新的第一次按 C
                            manager.isFirstC = true
                            manager.lastCommandCTime = currentTime
                            return Unmanaged.passRetained(event)
                        }
                    }
                }
                
            default:
                break
            }
            
            return Unmanaged.passRetained(event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("无法创建事件监听器")
            return
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("全局监听器设置成功")
        }
    }
    
    func register(translationHandler: @escaping () -> Void) {
        print("注册翻译回调")
        translationCallback = translationHandler
    }
    
    private func handleTranslation() {
        print("处理翻译请求")
        
        // 等待一小段时间，确保复制操作完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 获取剪贴板内容
            guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
                print("剪贴板内容为空")
                return
            }
            
            print("获取到剪贴板内容：\(clipboardText)")
            
            // 找到主窗口
            guard let window = NSApplication.shared.windows.first else {
                print("找不到主窗口")
                return
            }
            
            // 显示窗口并激活应用
            if !window.isVisible {
                print("显示窗口")
                window.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
                window.center()
            }
            
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            
            // 触发翻译回调
            self.translationCallback?()
        }
    }
    
    deinit {
        permissionCheckTimer?.invalidate()
        disableMonitor()
    }
} 