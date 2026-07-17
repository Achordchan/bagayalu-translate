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
        case composeFailed

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
            case .composeFailed:
                return "跨屏截图合成失败"
            }
        }
    }

    /// 从 NSScreen 提前提取可跨隔离域传递的值类型。
    private struct ScreenCaptureTarget: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    @MainActor
    static func capture(rect: CGRect) async throws -> NSImage {
        let integral = rect.integral
        guard integral.width > 2, integral.height > 2 else { throw CaptureError.invalidRect }

        let targets = NSScreen.screens.compactMap { screen -> ScreenCaptureTarget? in
            guard screen.frame.intersects(integral) else { return nil }
            return makeTarget(from: screen)
        }
        guard !targets.isEmpty else { throw CaptureError.noScreen }

        // 单屏：也裁到屏幕交集，避免虚拟桌面空白区域被带进 sourceRect。
        if targets.count == 1 {
            let target = targets[0]
            let clipped = integral.intersection(target.frame).integral
            guard clipped.width > 2, clipped.height > 2 else { throw CaptureError.invalidRect }
            return try await captureSingleTarget(target: target, rectInScreen: clipped)
        }

        // 跨屏：按显示器切分截图，再按全局坐标合成。
        let content = try await shareableContent()
        var pieces: [(image: CGImage, originInUnion: CGPoint, scale: CGFloat)] = []
        pieces.reserveCapacity(targets.count)

        for target in targets {
            let layouts = ScreenRegionComposeMath.layouts(
                selection: integral,
                screenFrames: [target.frame]
            )
            guard let layout = layouts.first else { continue }
            let piece = try await captureCGImage(
                target: target,
                rectInScreen: layout.rectInScreen,
                content: content
            )
            pieces.append((piece, layout.originInUnionTopLeft, target.scale))
        }

        guard !pieces.isEmpty else { throw CaptureError.displayNotFound }
        if pieces.count == 1 {
            let only = pieces[0]
            return NSImage(cgImage: only.image, size: integral.size)
        }

        let outputScale = pieces.map(\.scale).max() ?? 2
        let pixelWidth = Int((integral.width * outputScale).rounded(.up))
        let pixelHeight = Int((integral.height * outputScale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else { throw CaptureError.invalidRect }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.composeFailed
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // pieces.originInUnion 使用“左上原点 / y 向下”的合成坐标。
        // CGContext 默认左下原点，因此 y 需要翻转。
        for piece in pieces {
            let drawRect = ScreenRegionComposeMath.drawRectInCGContext(
                originInUnionTopLeft: piece.originInUnion,
                imagePixelSize: CGSize(width: piece.image.width, height: piece.image.height),
                imageScale: piece.scale,
                outputScale: outputScale,
                unionHeightPoints: integral.height
            )
            context.draw(piece.image, in: drawRect)
        }

        guard let composed = context.makeImage() else {
            throw CaptureError.composeFailed
        }
        return NSImage(cgImage: composed, size: integral.size)
    }

    @MainActor
    private static func makeTarget(from screen: NSScreen) -> ScreenCaptureTarget? {
        guard let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return nil
        }
        return ScreenCaptureTarget(
            displayID: displayID,
            frame: screen.frame,
            scale: screen.backingScaleFactor
        )
    }

    @MainActor
    private static func captureSingleTarget(
        target: ScreenCaptureTarget,
        rectInScreen: CGRect
    ) async throws -> NSImage {
        let content = try await shareableContent()
        let image = try await captureCGImage(
            target: target,
            rectInScreen: rectInScreen,
            content: content
        )
        return NSImage(cgImage: image, size: rectInScreen.size)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
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
    }

    private static func captureCGImage(
        target: ScreenCaptureTarget,
        rectInScreen: CGRect,
        content: SCShareableContent
    ) async throws -> CGImage {
        guard let scDisplay = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw CaptureError.displayNotFound
        }

        let screenFrame = target.frame
        let localX = rectInScreen.minX - screenFrame.minX
        let localY = screenFrame.maxY - rectInScreen.maxY
        let sourceRect = CGRect(
            x: localX,
            y: localY,
            width: rectInScreen.width,
            height: rectInScreen.height
        )

        let scale = target.scale
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(1, Int((sourceRect.width * scale).rounded()))
        config.height = max(1, Int((sourceRect.height * scale).rounded()))

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        return try await withCheckedThrowingContinuation { continuation in
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
    }
}
