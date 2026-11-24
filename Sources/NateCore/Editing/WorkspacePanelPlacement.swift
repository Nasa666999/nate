import Foundation

public enum WorkspacePanel: String, Codable, Sendable, CaseIterable {
    case directory
    case projects
    case structure
    case results
    case documentMap

    /// 业务作用：菜单、停靠标签和浮动面板共用一致的用户可见名称。
    /// 参数说明: 无。
    /// 返回：当前面板的明确名称。
    public var title: String {
        switch self {
        case .directory: "目录工作区"
        case .projects: "项目"
        case .structure: "函数列表"
        case .results: "搜索结果与输出"
        case .documentMap: "文档地图"
        }
    }

    /// 业务作用：首次打开窗口时给不同用途的面板提供既有工作区位置。
    /// 参数说明: 无。
    /// 返回：目录和项目在左边，结构和地图在右边，结果在底部。
    public var defaultPlacement: WorkspacePanelPlacement {
        switch self {
        case .directory, .projects: .left
        case .structure, .documentMap: .right
        case .results: .bottom
        }
    }
}

public enum WorkspacePanelPlacement: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom
    case floating

    /// 业务作用：用原生界面方位标明当前面板的具体位置。
    /// 参数说明: 无。
    /// 返回：停靠边或浮动模式的名称。
    public var title: String {
        switch self {
        case .left: "停靠左侧"
        case .right: "停靠右侧"
        case .top: "停靠顶部"
        case .bottom: "停靠底部"
        case .floating: "浮动"
        }
    }
}

public struct WorkspacePanelSession: Codable, Sendable, Equatable {
    public let panel: WorkspacePanel
    public let placement: WorkspacePanelPlacement
    public let visible: Bool
    public let selected: Bool
    public let floatingFrame: WindowSessionFrame?
    public let extent: Double?

    /// 业务作用：保存面板的位置和可见性，返回浮动时仍可使用原位置。
    /// 参数说明:
    /// - panel: 窗口内独立的面板身份。
    /// - placement: 当前停靠边或浮动方式。
    /// - visible: 面板是否在当前窗口打开。
    /// - selected: 面板是否为同一停靠组中正在展示的标签。
    /// - floatingFrame: 上次浮动使用的原生屏幕几何。
    /// - extent: 停靠组的实际宽度或高度，浮动时为空。
    /// 返回：待窗口布局整体复验的面板状态。
    public init(
        panel: WorkspacePanel,
        placement: WorkspacePanelPlacement,
        visible: Bool,
        selected: Bool,
        floatingFrame: WindowSessionFrame?,
        extent: Double? = nil
    ) {
        self.panel = panel
        self.placement = placement
        self.visible = visible
        self.selected = selected
        self.floatingFrame = floatingFrame
        self.extent = extent
    }
}
