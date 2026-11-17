import Foundation
import NateCore

public enum ProjectNodeKind: String, Codable, Sendable {
    case project
    case folder
    case file
}

public struct ProjectNode: Codable, Sendable, Equatable {
    public let id: UUID
    public var parent: UUID?
    public var kind: ProjectNodeKind
    public var name: String
    public var path: String?

    /// 业务作用：描述虚拟项目、分组或文件引用，创建值本身不探测或修改磁盘路径。
    /// 参数说明:
    /// - id: 该虚拟节点的稳定身份。
    /// - parent: 父分组身份，项目根为空。
    /// - kind: 节点的业务角色。
    /// - name: 目录树中使用的完整显示名称。
    /// - path: 文件引用的原始路径，非文件节点为空。
    /// 返回：待工作区整体验证的节点值，不授予任何文件访问权限。
    public init(
        id: UUID = UUID(),
        parent: UUID?,
        kind: ProjectNodeKind,
        name: String,
        path: String? = nil
    ) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.name = name
        self.path = path
    }

    /// 业务作用：按完整原文字节识别项目定义变化，规范等价的不同路径不能被当成同一次配置。
    /// 参数说明:
    /// - lhs: 原节点。
    /// - rhs: 待比较节点。
    /// 返回：身份、结构、角色、名称及可选路径字节全部相同时为真。
    public static func == (lhs: ProjectNode, rhs: ProjectNode) -> Bool {
        guard lhs.id == rhs.id, lhs.parent == rhs.parent, lhs.kind == rhs.kind,
            lhs.name.utf8.elementsEqual(rhs.name.utf8)
        else {
            return false
        }
        switch (lhs.path, rhs.path) {
        case (nil, nil):
            return true
        case (.some(let first), .some(let second)):
            return first.utf8.elementsEqual(second.utf8)
        default:
            return false
        }
    }
}

public struct ProjectWorkspace: Codable, Sendable, Equatable {
    private var format = 1
    public private(set) var nodes: [ProjectNode] = []

    enum CodingKeys: String, CodingKey {
        case format, nodes
    }

    /// 业务作用：建立不引用任何磁盘内容的空项目工作区，面板可独立载入和修改自己的集合。
    /// 参数说明: 无。
    /// 返回：已知格式的空虚拟集合，不创建默认项目或自动打开文件。
    public init() {}

    /// 业务作用：一次性建立完整虚拟结构，任何无效节点都阻止部分结构进入工作区。
    /// 参数说明:
    /// - nodes: 按同级显示顺序排列的扁平节点集合。
    /// 返回：角色、路径、身份、层级与容量均合法的工作区，否则失败且不发布部分值。
    public init(nodes: [ProjectNode]) throws {
        self.nodes = nodes
        try validate()
    }

    /// 业务作用：读取扁平项目定义并验证全部父关系，递归 JSON 结构不承担项目树层级。
    /// 参数说明:
    /// - decoder: 已由调用方限制归档容量的解码器。
    /// 返回：完整有效工作区；未知格式、错误字段及无效结构失败，不重置为空集合。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(Int.self, forKey: .format)
        // 未知格式不能先解释节点后再覆盖保存，读取端必须保留原归档。
        guard format == 1 else {
            throw NateError.message("项目工作区格式无法识别，原定义应保持不变。")
        }
        nodes = try values.decode([ProjectNode].self, forKey: .nodes)
        try validate()
    }

    /// 业务作用：验证虚拟定义的完整结构与容量，不探测文件存在性，不连接清单中的本地或远程位置。
    /// 参数说明: 无。
    /// 返回：最多 20000 节点、64 层、4 MiB 原文且身份与父关系合法时通过，否则明确失败。
    public func validate() throws {
        guard format == 1, nodes.count <= 20_000 else {
            throw NateError.message("项目格式无法识别或节点超过 20000 项。")
        }
        var identities: [UUID: ProjectNode] = [:]
        var remaining = 4 * 1024 * 1024
        for node in nodes {
            guard identities.updateValue(node, forKey: node.id) == nil else {
                throw NateError.message("项目包含重复节点身份。")
            }
            let nameBytes = node.name.utf8.count
            guard nameBytes > 0, nameBytes <= 1024, !node.name.utf8.contains(0),
                nameBytes <= remaining
            else {
                throw NateError.message("项目节点名称为空、包含 NUL、超过 1024 字节或使定义原文超过 4 MiB。")
            }
            remaining -= nameBytes
            if node.kind == .file {
                guard let path = node.path, !path.isEmpty, path.utf8.count <= 16_384,
                    !path.utf8.contains(0), path.utf8.count <= remaining
                else {
                    throw NateError.message("项目文件引用路径为空、包含 NUL、超过 16 KiB 或使定义原文超过 4 MiB。")
                }
                remaining -= path.utf8.count
            }
            else {
                guard node.path == nil, !node.name.contains("\n"), !node.name.contains("\r"),
                    !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw NateError.message("虚拟项目和文件夹只保存单行非空名称，不能携带文件路径。")
                }
            }
        }
        for node in nodes {
            if node.kind == .project {
                guard node.parent == nil else {
                    throw NateError.message("项目只能位于工作区根层。")
                }
            }
            else {
                // 文件和虚拟文件夹必须依附仍存在的项目或分组，缺少父节点时不能自动移到根层。
                guard let parent = node.parent, parent != node.id,
                    let owner = identities[parent], owner.kind != .file
                else {
                    throw NateError.message("项目节点缺少有效父分组。")
                }
            }
            var ancestors: Set<UUID> = [node.id]
            var parent = node.parent
            while let identity = parent {
                guard ancestors.insert(identity).inserted else {
                    throw NateError.message("项目父关系包含循环。")
                }
                guard ancestors.count <= 64 else {
                    throw NateError.message("项目层级超过 64 层。")
                }
                parent = identities[identity]?.parent
            }
        }
    }

    /// 业务作用：按虚拟结构顺序列出文件引用，搜索与打开的调用方仍须独立取得实际路径访问权限。
    /// 参数说明: 无。
    /// 返回：完整文件节点，不访问磁盘，不把清单载入等同于文件可用性检查。
    public var files: [ProjectNode] {
        var children: [UUID: [ProjectNode]] = [:]
        for node in nodes {
            if let parent = node.parent {
                children[parent, default: []].append(node)
            }
        }
        var pending = Array(
            nodes.filter {
                $0.parent == nil
            }.reversed()
        )
        var files: [ProjectNode] = []
        while let node = pending.popLast() {
            if node.kind == .file {
                files.append(node)
            }
            else {
                pending.append(contentsOf: (children[node.id] ?? []).reversed())
            }
        }
        return files
    }
}
