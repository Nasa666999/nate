import Foundation
import NateCore

public struct SidebarProjectSnapshot: Codable, Sendable, Equatable {
    public var workspace: ProjectWorkspace?
    public var saved: ProjectWorkspace?
    public var definitionPath: String?
    public var baseline: DiskBaseline?
    public var saveBlocked: Bool
    public var needsBindingVerification: Bool?
    public var expanded: [UUID]
    public var selected: UUID?

    /// 业务作用：保存一个独立项目面板的当前定义、保存点和树状态，不授予引用文件或定义文件访问权。
    /// 参数说明:
    /// - workspace: 当前完整虚拟结构，空值表示未载入。
    /// - saved: 最近确认写入的定义，用于恢复未保存状态。
    /// - definitionPath: 原定义文件的显示路径，恢复后仍需重新取得写入证据。
    /// - baseline: 原定义保存时的磁盘证据，不能单独作为恢复后的覆盖授权。
    /// - saveBlocked: 是否禁止普通覆盖，包括未确认发布或待复验原路径。
    /// - needsBindingVerification: 是否仅需在显式保存时复验原定义证据，旧归档可为空。
    /// - expanded: 已展开的虚拟分组身份。
    /// - selected: 当前选中的稳定节点身份。
    /// 返回：待完整归档验证的纯数据，不读取任何引用路径。
    public init(
        workspace: ProjectWorkspace? = nil,
        saved: ProjectWorkspace? = nil,
        definitionPath: String? = nil,
        baseline: DiskBaseline? = nil,
        saveBlocked: Bool = false,
        needsBindingVerification: Bool? = nil,
        expanded: [UUID] = [],
        selected: UUID? = nil
    ) {
        self.workspace = workspace
        self.saved = saved
        self.definitionPath = definitionPath
        self.baseline = baseline
        self.saveBlocked = saveBlocked
        self.needsBindingVerification = needsBindingVerification
        self.expanded = expanded
        self.selected = selected
    }

    /// 业务作用：区分原文字节不同的定义路径，规范等价名称不能阻止新的侧栏状态持久化。
    /// 参数说明:
    /// - lhs: 原面板快照。
    /// - rhs: 待比较的面板快照。
    /// 返回：完整定义、保存点、原路径字节和树状态均相同时为真。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace == rhs.workspace && lhs.saved == rhs.saved
            && lhs.definitionPath.map {
                Data($0.utf8)
            }
                == rhs.definitionPath.map {
                    Data($0.utf8)
                }
            && lhs.baseline == rhs.baseline && lhs.saveBlocked == rhs.saveBlocked
            && lhs.needsBindingVerification == rhs.needsBindingVerification
            && lhs.expanded == rhs.expanded && lhs.selected == rhs.selected
    }

    /// 业务作用：恢复必须具有完整当前定义和相容的树状态，缺失节点不能被猜测为另一文件或默认空集合。
    /// 参数说明: 无。
    /// 返回：定义、保存点、路径和节点身份全部合法时通过，否则整份侧栏归档失败。
    public func validate() throws {
        try workspace?.validate()
        try saved?.validate()
        if let definitionPath {
            try SidebarRecoveryState.validatePath(definitionPath)
        }
        guard workspace != nil || saved == nil && definitionPath == nil && baseline == nil && !saveBlocked,
            definitionPath != nil || baseline == nil,
            needsBindingVerification != true
                || definitionPath != nil && baseline != nil && saved != nil && saveBlocked,
            expanded.count <= 20_000, Set(expanded).count == expanded.count
        else {
            throw NateError.message("项目恢复定义、原路径或展开状态不完整。")
        }
        let nodes = workspace?.nodes ?? []
        let folders = Set(
            nodes.filter {
                $0.kind != .file
            }.map(\.id)
        )
        guard Set(expanded).isSubset(of: folders),
            selected == nil
                || nodes.contains(where: {
                    $0.id == selected
                })
        else {
            throw NateError.message("项目恢复的选择或展开节点不属于当前定义。")
        }
    }
}

public struct SidebarDirectorySnapshot: Codable, Sendable, Equatable {
    public var root: String
    public var expanded: [String]
    public var selected: String?

    /// 业务作用：保留目录根和显示意图，启动恢复只还原待连接树，不自动遍历原目录或挂载网络位置。
    /// 参数说明:
    /// - root: 原目录工作区的绝对根路径。
    /// - expanded: 原根内已展开的至多 64 个目录。
    /// - selected: 原根内当前选中的目录或文件。
    /// 返回：没有文件描述符和观察任务的纯路径快照。
    public init(root: String, expanded: [String] = [], selected: String? = nil) {
        self.root = root
        self.expanded = expanded
        self.selected = selected
    }

    /// 业务作用：目录路径按完整原文字节比较，视觉相同但编码不同的根或选择仍属于不同状态。
    /// 参数说明:
    /// - lhs: 原目录快照。
    /// - rhs: 当前目录快照。
    /// 返回：根、全部展开路径及可选选择字节一致时为真。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root.utf8.elementsEqual(rhs.root.utf8)
            && lhs.expanded.count == rhs.expanded.count
            && zip(lhs.expanded, rhs.expanded).allSatisfy {
                $0.utf8.elementsEqual($1.utf8)
            }
            && lhs.selected.map {
                Data($0.utf8)
            }
                == rhs.selected.map {
                    Data($0.utf8)
                }
    }

    /// 业务作用：所有恢复目录意图限制在原根之内，只验证路径数据，不触碰磁盘或解析符号链接。
    /// 参数说明: 无。
    /// 返回：根、选择、展开数量及原字节层级均合法时通过，否则整份侧栏归档失败。
    public func validate() throws {
        try SidebarRecoveryState.validatePath(root)
        guard expanded.count <= 64,
            Set(
                expanded.map {
                    Data($0.utf8)
                }
            ).count == expanded.count
        else {
            throw NateError.message("目录恢复展开状态重复或超过 64 项。")
        }
        let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        guard canonicalRoot.utf8.elementsEqual(root.utf8) else {
            throw NateError.message("目录恢复根不是规范绝对路径。")
        }
        let prefix = Data((root == "/" ? root : root + "/").utf8)
        for path in expanded
            + (selected.map {
                [$0]
            } ?? [])
        {
            try SidebarRecoveryState.validatePath(path)
            guard URL(fileURLWithPath: path).standardizedFileURL.path.utf8.elementsEqual(path.utf8),
                path.utf8.elementsEqual(root.utf8) || Data(path.utf8).starts(with: prefix)
            else {
                throw NateError.message("目录恢复路径超出原根或含有未消解的层级。")
            }
        }
    }
}

public struct SidebarRecoveryState: Codable, Sendable, Equatable {
    private var format = 1
    public var projects: [SidebarProjectSnapshot]
    public var selectedProject: Int
    public var projectsVisible: Bool
    public var directory: SidebarDirectorySnapshot?

    /// 业务作用：把三个虚拟项目与一个真实目录工作区作为同一份侧栏快照保护，与正文恢复通道保持独立。
    /// 参数说明:
    /// - projects: 三个独立面板的完整快照，缺省为空面板。
    /// - selectedProject: 当前项目面板索引，范围为零至二。
    /// - projectsVisible: 项目区域是否可见。
    /// - directory: 原目录工作区，没有根时为空。
    /// 返回：待验证和编码的完整侧栏状态，不打开文件或改变原路径内容。
    public init(
        projects: [SidebarProjectSnapshot] = Array(repeating: SidebarProjectSnapshot(), count: 3),
        selectedProject: Int = 0,
        projectsVisible: Bool = false,
        directory: SidebarDirectorySnapshot? = nil
    ) {
        self.projects = projects
        self.selectedProject = selectedProject
        self.projectsVisible = projectsVisible
        self.directory = directory
    }

    /// 业务作用：未知格式或缺失面板不退化成空工作区，恢复与发布共同使用完整数据合同。
    /// 参数说明: 无。
    /// 返回：已知格式、三个完整面板及合法目录状态通过，否则保留原归档并停止自动覆盖。
    public func validate() throws {
        guard format == 1, projects.count == 3, (0..<3).contains(selectedProject) else {
            throw NateError.message("侧栏恢复格式、面板数量或当前面板无法识别。")
        }
        for project in projects {
            try project.validate()
        }
        try directory?.validate()
    }

    /// 业务作用：恢复路径仅接受有界的本机绝对路径数据，不能把残缺或 NUL 内容转换成其它访问目标。
    /// 参数说明:
    /// - path: 尚未取得文件访问权的原始路径。
    /// 返回：非空、无 NUL 且不超过 16 KiB 的绝对路径通过；本函数不确认路径存在。
    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.utf8.contains(0) else {
            throw NateError.message("侧栏恢复路径不是有界的绝对路径。")
        }
    }
}
