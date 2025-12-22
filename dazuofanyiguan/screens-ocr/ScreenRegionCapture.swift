import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// 截取屏幕上的一个矩形区域。
// rect 使用“屏幕坐标”（全局坐标系）：原点在主屏左下角。

enum ScreenRegionCapture {
    enum CaptureError: LocalizedError {
        case invalidRect
        case noScreen
        case shareableContentFailed(String)
        case displayNotFound
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRect:
                return "截图区域无效"
            case .noScreen:
                return "无法获取屏幕信息"
            case .shareableContentFailed(let msg):
                return "获取可截图内容失败：\(msg)"
            case .displayNotFound:
                return "无法匹配到目标显示器"
            case .captureFailed(let msg):
                return "截图失败：\(msg)"
            }
        }
    }

    @MainActor
    static func capture(rect: CGRect) async throws -> NSImage {
        let integral = rect.integral
        guard integral.width > 2, integral.height > 2 else { throw CaptureError.invalidRect }

        let center = CGPoint(x: integral.midX, y: integral.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else {
            throw CaptureError.noScreen
        }

        guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw CaptureError.noScreen
        }

        let content: SCShareableContent = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: CaptureError.shareableContentFailed(error.localizedDescription))
                    return
                }
                guard let content else {
                    continuation.resume(throwing: CaptureError.shareableContentFailed("content is nil"))
                    return
                }
                continuation.resume(returning: content)
            }
        }

        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        // 将“全局屏幕坐标（左下原点）”转换为“display 内局部坐标”。
        // ScreenCaptureKit 的 sourceRect 坐标系以显示器内容为基准，y 轴方向与 AppKit 屏幕坐标相反。
        // localX: 距离该屏幕左边界
        // localY: 距离该屏幕上边界（因此需要把 y 翻转）
        let screenFrame = screen.frame
        let localX = integral.minX - screenFrame.minX
        let localY = screenFrame.maxY - integral.maxY
        let sourceRect = CGRect(x: localX, y: localY, width: integral.width, height: integral.height)

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error {
                    continuation.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
                    return
                }
                guard let image else {
                    continuation.resume(throwing: CaptureError.captureFailed("image is nil"))
                    return
                }
                continuation.resume(returning: image)
            }
        }

        // 注意：NSImage 的 size 用 point（而不是 pixel）。
        // 这样在 SwiftUI 里显示截图时，尺寸能和屏幕坐标（point）对齐。
        // OCR 仍然使用底层 cgImage，不受这里 size 的影响。
        return NSImage(cgImage: cgImage, size: integral.size)
    }
}
