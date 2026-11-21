import AppKit

@MainActor
final class TabCanvas: NSView {
    private(set) var arrangedSubviews: [NSView] = []

    /// 业务作用：标签按阅读顺序自上而下排列，垂直与多行滚动使用同一顶部原点。
    /// 参数说明: 无。
    /// 返回：内容坐标采用顶部原点。
    override var isFlipped: Bool {
        true
    }

    /// 业务作用：记录稳定顺序的原生标签容器，具体位置由完整布局计划统一发布。
    /// 参数说明:
    /// - view: 一个文档的原生标题及关闭按钮容器。
    /// 返回：容器加入内容视图，尚不改变正文或布局模式。
    func addArrangedSubview(_ view: NSView) {
        arrangedSubviews.append(view)
        addSubview(view)
    }

    /// 业务作用：文档顺序改变时收回原容器的排列身份，实际视图释放由调用方完成。
    /// 参数说明:
    /// - view: 待移出顺序的原容器。
    /// 返回：只移除对应实例，不按标题或路径猜测另一文档。
    func removeArrangedSubview(_ view: NSView) {
        arrangedSubviews.removeAll {
            $0 === view
        }
    }
}
