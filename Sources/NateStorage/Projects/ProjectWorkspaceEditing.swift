import Foundation
import NateCore

extension ProjectWorkspace {
    /// 业务作用：把一批虚拟节点作为一次定义变化加入工作区，失败时保留原集合。
    /// 参数说明:
    /// - additions: 已固定身份和父关系的新节点。
    /// 返回：全部合法才整体加入，不创建文件或目录，不允许部分加入。
    public mutating func insert(_ additions: [ProjectNode]) throws {
        guard additions.count <= 20_000 - nodes.count else {
            throw NateError.message("项目节点超过 20000 项，未加入部分内容。")
        }
        let candidate = try ProjectWorkspace(nodes: nodes + additions)
        self = candidate
    }

    /// 业务作用：改变虚拟节点显示名称，项目分组或文件别名改名不重命名磁盘文件。
    /// 参数说明:
    /// - id: 需要改名的稳定虚拟身份。
    /// - name: 完整新显示名称。
    /// 返回：有效名称整体发布；身份缺失或名称无效时原定义不变。
    public mutating func rename(_ id: UUID, to name: String) throws {
        guard
            let index = nodes.firstIndex(where: {
                $0.id == id
            })
        else {
            throw NateError.message("原项目节点已不存在。")
        }
        var candidate = nodes
        candidate[index].name = name
        self = try ProjectWorkspace(nodes: candidate)
    }

    /// 业务作用：重新指定一个文件引用的路径，不移动、重命名或打开任一实际文件。
    /// 参数说明:
    /// - id: 当前文件引用身份。
    /// - path: 仍待访问权限确认的原始新路径。
    /// 返回：路径合法时发布引用，名称保留；非文件节点、失效身份或无效路径失败。
    public mutating func changeReference(_ id: UUID, to path: String) throws {
        guard
            let index = nodes.firstIndex(where: {
                $0.id == id
            }), nodes[index].kind == .file
        else {
            throw NateError.message("当前节点不是仍存在的文件引用。")
        }
        var candidate = nodes
        candidate[index].path = path
        self = try ProjectWorkspace(nodes: candidate)
    }

    /// 业务作用：在虚拟分组间移动节点，父关系变化不能制造循环、悬空节点或嵌套项目。
    /// 参数说明:
    /// - id: 待移动的虚拟身份。
    /// - parent: 新父分组，项目根保持为空。
    /// 返回：完整新结构有效才发布，不移动任何磁盘路径。
    public mutating func relocate(_ id: UUID, to parent: UUID?) throws {
        guard
            let index = nodes.firstIndex(where: {
                $0.id == id
            })
        else {
            throw NateError.message("原项目节点已不存在。")
        }
        var candidate = nodes
        candidate[index].parent = parent
        // 先验证整棵候选结构，后替换定义，非法父关系不能造成半完成的移动。
        self = try ProjectWorkspace(nodes: candidate)
    }

    /// 业务作用：同级虚拟节点上下调整显示顺序，文件引用与分组关系保持不变。
    /// 参数说明:
    /// - id: 需要移动的稳定身份。
    /// - offset: 向上为负一，向下为正一。
    /// 返回：存在相邻同级节点时交换顺序并返回真；边界无变化，非法方向或失效身份失败。
    @discardableResult public mutating func moveSibling(_ id: UUID, offset: Int) throws -> Bool {
        guard offset == -1 || offset == 1,
            let index = nodes.firstIndex(where: {
                $0.id == id
            })
        else {
            throw NateError.message("同级移动方向或节点身份无效。")
        }
        let parent = nodes[index].parent
        let siblings = nodes.indices.filter {
            nodes[$0].parent == parent
        }
        guard let current = siblings.firstIndex(of: index), siblings.indices.contains(current + offset) else {
            return false
        }
        var candidate = nodes
        candidate.swapAt(index, siblings[current + offset])
        self = try ProjectWorkspace(nodes: candidate)
        return true
    }

    /// 业务作用：移除虚拟项目、分组及其后代引用，磁盘文件和已打开正文保持原状。
    /// 参数说明:
    /// - id: 需要移出的稳定节点身份。
    /// 返回：仅定义中的对应子树被移除；身份不存在时失败，不删除任何磁盘内容。
    public mutating func remove(_ id: UUID) throws {
        guard
            nodes.contains(where: {
                $0.id == id
            })
        else {
            throw NateError.message("原项目节点已不存在。")
        }
        var children: [UUID: [ProjectNode]] = [:]
        for node in nodes {
            if let parent = node.parent {
                children[parent, default: []].append(node)
            }
        }
        var removed: Set<UUID> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] {
                removed.insert(child.id)
                pending.append(child.id)
            }
        }
        self = try ProjectWorkspace(
            nodes: nodes.filter {
                !removed.contains($0.id)
            }
        )
    }
}
