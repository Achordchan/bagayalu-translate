import AppKit
import ApplicationServices
import Foundation

// 屏幕录制权限（Screen Recording）检查与触发申请
//
// 注意：
// - 截图识别要读取屏幕像素，这在 macOS 上通常需要“屏幕录制”权限。
// - 这里使用系统 API：CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess。

enum ScreenCapturePermission {
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func ensurePermission() async -> Bool {
        if hasPermission() {
            return true
        }

        // 会弹系统授权弹窗。
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            return hasPermission()
        }
        return false
    }

    @MainActor
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
