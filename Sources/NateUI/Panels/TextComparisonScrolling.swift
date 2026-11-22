import AppKit

extension TextComparisonWindow {
    /// 业务作用：双侧可独立启用垂直与水平同步，通知重入不能在两个只读视图之间形成滚动循环。
    /// 参数说明:
    /// - notification: 两侧原生裁剪视图的边界变化。
    /// 返回：垂直按可滚动范围比例、水平按原始横向位置同步，关闭方向保持目标原位置。
    @objc func scrolled(_ notification: Notification) {
        guard !synchronizing, vertical.state == .on || horizontal.state == .on,
            let source = notification.object as? NSClipView,
            source === originalScroll.contentView || source === revisedScroll.contentView
        else {
            return
        }
        let targetScroll = source === originalScroll.contentView ? revisedScroll : originalScroll
        let target = targetScroll.contentView
        guard let sourceView = source.documentView, let targetView = target.documentView else {
            return
        }
        var point = target.bounds.origin
        if vertical.state == .on {
            let sourceMaximum = max(0, sourceView.frame.height - source.bounds.height)
            let targetMaximum = max(0, targetView.frame.height - target.bounds.height)
            let fraction = sourceMaximum > 0 ? min(1, max(0, source.bounds.minY / sourceMaximum)) : 0
            point.y = fraction * targetMaximum
        }
        if horizontal.state == .on {
            point.x = min(max(0, source.bounds.minX), max(0, targetView.frame.width - target.bounds.width))
        }
        guard point.x.isFinite, point.y.isFinite else {
            return
        }
        synchronizing = true
        defer {
            synchronizing = false
        }
        target.scroll(to: point)
        targetScroll.reflectScrolledClipView(target)
    }
}
