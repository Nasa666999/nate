import AppKit
import NateCore

extension TabStrip {
    /// 业务作用：用户切换标签方向时仅改变标签几何，原正文与输入法覆盖层继续由原视图持有。
    /// 参数说明:
    /// - mode: 已验证的目标标签布局。
    /// 返回：布局改变时撤销旧手势并复位标签视口；活动标签在窗口区域约束完成后显示，相同模式保持现状。
    func setLayout(_ mode: DocumentTabLayout) {
        guard mode != layoutMode else {
            return
        }
        if let active = activeDrag {
            endTitleDrag(active.gesture)
        }
        layoutMode = mode
        // 布局改变后旧命中位置不再代表当前目标，原顺序计划不能继续取得界面发布权。
        orderIdentity = UUID()
        for group in stack.arrangedSubviews {
            ((group as? NSStackView)?.arrangedSubviews.first as? TabButton)?.orderIdentity = orderIdentity
        }
        hasVerticalScroller = mode != .horizontal
        autohidesScrollers = true
        scrollerStyle = .overlay
        contentView.scroll(to: .zero)
        layoutTabs()
    }

    /// 业务作用：窗口宽度变化后重新计算标签行列，所有控件使用同一完整几何计划。
    /// 参数说明: 无。
    /// 返回：保留稳定控件和文档顺序，更新可滚动范围及有限多行高度。
    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// 业务作用：原生测量先受宽度约束，再一次发布全部标签几何，避免半套行列供拖动使用。
    /// 参数说明: 无。
    /// 返回：合法完整计划更新全部位置；尚无有效视口或正在布局时等待后续原生布局。
    func layoutTabs() {
        guard !layingOutTabs, current.count == stack.arrangedSubviews.count,
            contentView.bounds.width > 0
        else {
            return
        }
        layingOutTabs = true
        defer {
            layingOutTabs = false
        }
        let widths = stack.arrangedSubviews.map {
            view in
            let width = Double(view.fittingSize.width)
            return width.isFinite ? min(1_048_576, max(0, width)) : 72
        }
        guard
            let plan = try? DocumentTabLayoutPlan(
                mode: layoutMode,
                documentIDs: current.map(\.id),
                naturalWidths: widths,
                viewportWidth: Double(contentView.bounds.width)
            )
        else {
            return
        }
        layoutPlan = plan
        stack.frame.size = NSSize(
            width: plan.width,
            height: max(plan.height, Double(contentView.bounds.height))
        )
        for (view, cell) in zip(stack.arrangedSubviews, plan.cells) {
            view.frame = NSRect(
                x: cell.x,
                y: cell.y,
                width: cell.width,
                height: cell.height
            )
            view.layoutSubtreeIfNeeded()
        }
        let clip = contentView.bounds
        contentView.scroll(
            to: NSPoint(
                x: min(max(0, clip.minX), max(0, stack.bounds.width - clip.width)),
                y: min(max(0, clip.minY), max(0, stack.bounds.height - clip.height))
            )
        )
        reflectScrolledClipView(contentView)
        onRequiredHeight?(CGFloat(layoutMode == .multiline ? min(132, plan.height) : 33))
    }

    /// 业务作用：明确切换文档或布局后只滚动标签列表，让当前标签可见而不移动正文。
    /// 参数说明: 无。
    /// 返回：存在活动身份时显示其完整标签，其它状态不产生导航。
    func revealSelectedTab() {
        guard
            let index = current.firstIndex(where: {
                $0.selected
            }),
            stack.arrangedSubviews.indices.contains(index)
        else {
            return
        }
        stack.scrollToVisible(stack.arrangedSubviews[index].frame)
    }
}
