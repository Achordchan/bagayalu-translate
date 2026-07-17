import CoreGraphics
import Foundation

/// 跨屏截图切分与合成的纯坐标计算。
enum ScreenRegionComposeMath {
    struct PieceLayout: Equatable {
        let rectInScreen: CGRect
        /// 合成画布左上原点、y 向下的相对位置。
        let originInUnionTopLeft: CGPoint
    }

    /// 将全局选区按各显示器 frame 切分，并计算在联合选区中的贴图原点。
    static func layouts(
        selection: CGRect,
        screenFrames: [CGRect]
    ) -> [PieceLayout] {
        let integral = selection.integral
        var result: [PieceLayout] = []
        result.reserveCapacity(screenFrames.count)

        for frame in screenFrames {
            let intersection = integral.intersection(frame).integral
            guard intersection.width > 1, intersection.height > 1 else { continue }
            let origin = CGPoint(
                x: intersection.minX - integral.minX,
                y: integral.maxY - intersection.maxY
            )
            result.append(PieceLayout(rectInScreen: intersection, originInUnionTopLeft: origin))
        }
        return result
    }

    /// 合成时把“左上原点”贴图框转换为 CGContext 使用的“左下原点”绘制矩形。
    static func drawRectInCGContext(
        originInUnionTopLeft: CGPoint,
        imagePixelSize: CGSize,
        imageScale: CGFloat,
        outputScale: CGFloat,
        unionHeightPoints: CGFloat
    ) -> CGRect {
        let drawWidth = imagePixelSize.width * (outputScale / imageScale)
        let drawHeight = imagePixelSize.height * (outputScale / imageScale)
        return CGRect(
            x: originInUnionTopLeft.x * outputScale,
            y: (unionHeightPoints * outputScale) - (originInUnionTopLeft.y * outputScale) - drawHeight,
            width: drawWidth,
            height: drawHeight
        )
    }
}
