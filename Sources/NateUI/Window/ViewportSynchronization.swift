import AppKit

@MainActor
enum ViewportSynchronization {
    /// 业务作用：同步只读滚动位置，共享正文使用真实顶行，其它正文按完整可滚动范围比例定位。
    /// 参数说明:
    /// - source: 当前明确发生边界变化的源滚动容器。
    /// - target: 同一界面内已验证仍然有效的目标滚动容器。
    /// - vertical: 是否同步垂直方向。
    /// - horizontal: 是否同步水平方向。
    /// - matchingLines: 共享正文是否按真实行锚点同步，比较不同快照时保持关闭。
    /// 返回：有效完整视口进入目标；未确认输入、编辑保护、过期排版或非法几何保持原位置，不改变选区或正文。
    static func apply(
        from source: NSScrollView,
        to target: NSScrollView,
        vertical: Bool,
        horizontal: Bool,
        matchingLines: Bool
    ) {
        // 候选、保护状态和旧修订的排版没有当前像素定位权，不能用其几何移动另一个视图。
        guard vertical || horizontal,
            let sourceView = source.documentView as? EditorView,
            let targetView = target.documentView as? EditorView,
            !sourceView.hasComposition, !targetView.hasComposition,
            !sourceView.document.isEditingSuspended, !targetView.document.isEditingSuspended,
            sourceView.observedRevision == sourceView.document.revision,
            targetView.observedRevision == targetView.document.revision
        else {
            return
        }
        let sourceClip = source.contentView, targetClip = target.contentView
        if matchingLines, sourceView.document === targetView.document,
            let anchor = sourceView.viewportAnchor(), let current = targetView.viewportAnchor()
        {
            guard anchor.offset.isFinite, anchor.x.isFinite, current.offset.isFinite, current.x.isFinite
            else {
                return
            }
            targetView.restoreViewportAnchor(
                EditorViewportAnchor(
                    line: vertical ? anchor.line : current.line,
                    offset: vertical ? anchor.offset : current.offset,
                    x: horizontal ? anchor.x : current.x
                )
            )
            return
        }
        var point = targetClip.bounds.origin
        if vertical {
            let sourceMaximum = max(0, sourceView.frame.height - sourceClip.bounds.height)
            let targetMaximum = max(0, targetView.frame.height - targetClip.bounds.height)
            let fraction = sourceMaximum > 0 ? min(1, max(0, sourceClip.bounds.minY / sourceMaximum)) : 0
            point.y = fraction * targetMaximum
        }
        if horizontal {
            point.x = min(
                max(0, sourceClip.bounds.minX),
                max(0, targetView.frame.width - targetClip.bounds.width)
            )
        }
        guard point.x.isFinite, point.y.isFinite else {
            return
        }
        targetClip.scroll(to: point)
        target.reflectScrolledClipView(targetClip)
    }
}
