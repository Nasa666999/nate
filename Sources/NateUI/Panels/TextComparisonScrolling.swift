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
        let sourceScroll = source === originalScroll.contentView ? originalScroll : revisedScroll
        let targetScroll = sourceScroll === originalScroll ? revisedScroll : originalScroll
        synchronizing = true
        defer {
            synchronizing = false
        }
        ViewportSynchronization.apply(
            from: sourceScroll,
            to: targetScroll,
            vertical: vertical.state == .on,
            horizontal: horizontal.state == .on,
            matchingLines: false
        )
    }
}
