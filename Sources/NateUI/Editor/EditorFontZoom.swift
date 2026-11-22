import AppKit

extension EditorView {
    /// 业务作用：独立输出读取当前视图已经确认的点数差值，不从资源原字号反推临时缩放。
    /// 参数说明: 无。
    /// 返回：显式 UDL 字号的当前缩放差值；继承字体已经包含此缩放，不得再次叠加。
    public var fontZoomAdjustment: CGFloat {
        fontMetrics.zoomAdjustment
    }

    /// 业务作用：缩放同时调整基础和资源显式字号，重置回到本次配置的原基础字号。
    /// 参数说明:
    /// - points: 增减的点数，为空时重置为缩放前的配置字体。
    /// 返回：基础字号保持 7–72 点，各资源字号至少为 1 点；正文和原资源不改变。
    public func zoomFont(by points: CGFloat?) {
        // 非法调用不能污染后续排版身份，所有可见字号必须保持有限且有界。
        guard points?.isFinite != false else {
            return
        }
        let baseline = fontMetrics.zoomBaseFont ?? font
        let requested =
            points.map {
                font.pointSize + $0
            } ?? baseline.pointSize
        let size = max(7, min(72, requested))
        guard size != font.pointSize || (points == nil && fontMetrics.zoomAdjustment != 0) else {
            return
        }
        fontMetrics.zoomBaseFont = baseline
        fontMetrics.zoomAdjustment = size - baseline.pointSize
        font = NSFontManager.shared.convert(font, toSize: size)
        // 资源字号变化也改变像素坐标；先收回旧视觉动作，再让当前视图重建完整布局。
        updateRectangleStyleIdentity()
        projection.measured.removeAll()
        refresh()
    }

    /// 业务作用：明确应用显示设置建立新的缩放基准，不能把先前的临时差值带入新配置。
    /// 参数说明:
    /// - value: 用户已经确认的本机基础字体与字号。
    /// 返回：清除临时缩放并替换字体；所属窗口随后统一刷新全部视图。
    func setBaseFont(_ value: NSFont) {
        fontMetrics.zoomBaseFont = nil
        fontMetrics.zoomAdjustment = 0
        font = value
        updateRectangleStyleIdentity()
        projection.measured.removeAll()
    }

    /// 业务作用：新克隆继承来源视图的缩放基准与点数差值，之后仍可各自调整。
    /// 参数说明:
    /// - source: 创建克隆时的实际来源视图。
    /// 返回：只复制排版状态，不复制正文历史或候选；新克隆随后按自己的视口刷新。
    func copyFontZoom(from source: EditorView) {
        fontMetrics.zoomBaseFont = source.fontMetrics.zoomBaseFont
        fontMetrics.zoomAdjustment = source.fontMetrics.zoomAdjustment
        updateRectangleStyleIdentity()
        projection.measured.removeAll()
    }
}
