import AppKit
import NateCore

extension EditorWindow {
    /// 业务作用：提供当前真实标签布局供菜单和偏好呈现，不以正文语言推断窗口布局。
    /// 参数说明: 无。
    /// 返回：当前窗口实际采用的标签排列方式。
    public var documentTabLayout: DocumentTabLayout {
        tabs.layoutMode
    }

    /// 业务作用：在原生主窗口创建时接入可切换标签区域，正文和候选继续使用原视图。
    /// 参数说明:
    /// - root: 当前窗口唯一布局根视图。
    /// 返回：安装默认水平约束和有限多行高度回调，不建立另一个正文实例。
    func configureTabLayout(in root: NSView) {
        tabLayoutRoot = root
        tabHeight = tabs.heightAnchor.constraint(equalToConstant: 33)
        tabs.onRequiredHeight = {
            [weak self] height in
            guard let self, self.tabs.layoutMode != .vertical,
                self.tabHeight?.constant != height
            else {
                return
            }
            self.tabHeight?.constant = height
        }
        setDocumentTabLayout(.horizontal)
    }

    /// 业务作用：用户选择布局后仅重新约束标签和正文区域，保留活动实例、视口、候选及克隆关系。
    /// 参数说明:
    /// - mode: 完整验证后的窗口标签布局。
    /// 返回：水平与有限多行位于上方，垂直位于左侧；相同布局不会重置手势或滚动。
    public func setDocumentTabLayout(_ mode: DocumentTabLayout) {
        guard let root = tabLayoutRoot, mode != tabs.layoutMode || tabLayoutConstraints.isEmpty else {
            return
        }
        // 先撤销旧几何约束与手势，再发布完整新区域，旧坐标不能继续移动另一个标签。
        NSLayoutConstraint.deactivate(tabLayoutConstraints)
        tabs.setLayout(mode)
        if mode == .vertical {
            tabLayoutConstraints = [
                tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                tabs.widthAnchor.constraint(equalToConstant: 240),
                tabs.bottomAnchor.constraint(equalTo: status.topAnchor),
                incrementalSearch.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor),
                incrementalSearch.leadingAnchor.constraint(equalTo: tabs.trailingAnchor),
                split.leadingAnchor.constraint(equalTo: tabs.trailingAnchor),
            ]
        }
        else {
            tabLayoutConstraints = [
                tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                incrementalSearch.topAnchor.constraint(equalTo: tabs.bottomAnchor),
                incrementalSearch.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ]
            if let tabHeight {
                tabLayoutConstraints.append(tabHeight)
            }
        }
        NSLayoutConstraint.activate(tabLayoutConstraints)
        root.layoutSubtreeIfNeeded()
        tabs.layoutTabs()
        tabs.revealSelectedTab()
    }
}
