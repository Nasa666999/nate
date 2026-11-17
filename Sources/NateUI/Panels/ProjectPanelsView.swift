import AppKit

@MainActor
public final class ProjectPanelsView: NSView {
    public let panels = [
        ProjectTreePanel(frame: .zero),
        ProjectTreePanel(frame: .zero),
        ProjectTreePanel(frame: .zero),
    ]
    public var onAction: ((Int, String, UUID?) -> Void)?
    public var onOpen: ((Int, UUID) -> Void)?
    public var onHide: (() -> Void)?
    public var onSelectionChange: ((Int) -> Void)?
    public private(set) var selectedIndex = 0
    let selector = NSSegmentedControl(
        labels: ["1", "2", "3"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    /// 业务作用：三个独立原生项目面板共享侧栏区域，各自保留定义、选择、展开和菜单上下文。
    /// 参数说明:
    /// - frameRect: 工作区分配的初始布局。
    /// 返回：默认显示第一个面板，切换不清空另两个面板。
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "项目面板")
        title.font = .boldSystemFont(ofSize: 12)
        selector.controlSize = .small
        selector.segmentDistribution = .fillEqually
        selector.selectedSegment = 0
        selector.target = self
        selector.action = #selector(selectionChanged)
        selector.setAccessibilityLabel("独立项目面板选择")
        let close = NSButton(
            image: NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "隐藏项目面板"
            ) ?? NSImage(),
            target: self,
            action: #selector(hideAction)
        )
        close.bezelStyle = .inline
        let heading = NSStackView(views: [title, selector, NSView(), close])
        heading.spacing = 6
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
        for (index, panel) in panels.enumerated() {
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.isHidden = index != 0
            panel.onAction = {
                [weak self] action, node in self?.onAction?(index, action, node)
            }
            panel.onOpen = {
                [weak self] node in self?.onOpen?(index, node)
            }
            addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 3),
                panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    /// 业务作用：项目容器由当前窗口显式建立，不从原生归档取得路径或工作区定义。
    /// 参数说明:
    /// - coder: 系统归档。
    /// 返回：不支持归档初始化。
    required init?(coder: NSCoder) {
        nil
    }

    /// 业务作用：切换独立面板只改变可见性，不转移节点选择或文件访问权限。
    /// 参数说明:
    /// - index: 从零开始的三个面板索引。
    /// 返回：有效索引切换当前显示，无效索引不改变状态。
    public func select(_ index: Int) {
        guard panels.indices.contains(index) else {
            return
        }
        let changed = selectedIndex != index
        selectedIndex = index
        selector.selectedSegment = index
        for (candidate, panel) in panels.enumerated() {
            panel.isHidden = candidate != index
        }
        if changed {
            onSelectionChange?(index)
        }
    }

    /// 业务作用：原生分段选择与菜单定位共用同一面板切换入口。
    /// 参数说明: 无。
    /// 返回：当前原生选项成为可见面板，其他定义保持原状。
    @objc private func selectionChanged() {
        select(selector.selectedSegment)
    }

    /// 业务作用：隐藏整块项目侧栏只发出界面意图，不卸载任何工作区或删除虚拟节点。
    /// 参数说明: 无。
    /// 返回：应用处理侧栏可见性，三个面板内容继续保留。
    @objc private func hideAction() {
        onHide?()
    }
}
