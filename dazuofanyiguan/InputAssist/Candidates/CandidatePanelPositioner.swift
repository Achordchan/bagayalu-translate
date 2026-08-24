import AppKit
import Foundation

/// 候选浮层定位（PRD §16）。纯几何计算，不碰窗口，方便直接单测。
enum CandidatePanelPositioner {
    /// 浮层与文字之间的间距。太小会盖住光标，太大就不像输入法候选了。
    static let anchorGap: CGFloat = 6
    static let screenMargin: CGFloat = 8

    /// AX 矩形（左上原点）→ Cocoa 矩形（左下原点）。
    ///
    /// **必须用主屏高度翻转，不能用所有屏幕的全局 maxY。**
    /// 两套坐标系都以主屏（`screens[0]`，origin 恒为 0,0）为基准互为上下翻转；
    /// 用全局 maxY 的话，只要副屏比主屏更高或更靠上，整体就会偏移，
    /// 浮层直接落到另一台显示器上。这是 TypeTide issue #4 已经踩过的坑。
    static func cocoaRect(fromAXRect axRect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: primaryScreenMaxY - axRect.origin.y - axRect.size.height,
            width: axRect.size.width,
            height: axRect.size.height
        )
    }

    static func primaryScreenMaxY() -> CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.height ?? 0
    }

    /// 在锚点附近放一个 `panelSize` 的浮层，返回它的 origin（Cocoa 坐标）。
    ///
    /// 优先放在光标下方；下方空间不足就翻到上方（PRD §16.2）。
    /// `visibleFrame` 已经排除了菜单栏和 Dock，所以夹紧到它里面就同时满足了那两条避让要求。
    static func panelOrigin(
        anchorRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        var y = anchorRect.minY - anchorGap - panelSize.height
        if y < visibleFrame.minY + screenMargin {
            let above = anchorRect.maxY + anchorGap
            // 翻到上方也放不下时，保留「下方」这一侧，靠后面的夹紧收拾，
            // 免得在屏幕很矮的情况下来回横跳。
            if above + panelSize.height <= visibleFrame.maxY - screenMargin {
                y = above
            }
        }

        var x = anchorRect.minX
        if x + panelSize.width > visibleFrame.maxX - screenMargin {
            x = visibleFrame.maxX - screenMargin - panelSize.width
        }

        x = clamp(
            x,
            lower: visibleFrame.minX + screenMargin,
            upper: max(visibleFrame.minX + screenMargin, visibleFrame.maxX - screenMargin - panelSize.width)
        )
        y = clamp(
            y,
            lower: visibleFrame.minY + screenMargin,
            upper: max(visibleFrame.minY + screenMargin, visibleFrame.maxY - screenMargin - panelSize.height)
        )
        return CGPoint(x: x, y: y)
    }

    /// 锚点落在哪块屏幕上。多显示器下必须按锚点选屏，不能永远用 main。
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
