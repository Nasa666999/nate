import Foundation

public struct TabPresentation: Equatable {
    public var id: UUID
    public var title: String
    public var path: String?
    public var selected: Bool
    public var pinned: Bool
    public var dirty: Bool
    public var failed: Bool
    public var readOnly: Bool

    /// 业务作用：将真实文档状态映射为标签呈现，名称、路径和权限各自保留原含义。
    /// 参数说明:
    /// - id: 唯一文档身份。
    /// - title: 原始文档名称，不包含状态前缀。
    /// - path: 已关联文件的完整路径，只用于呈现。
    /// - selected: 当前活动状态。
    /// - pinned: 固定状态。
    /// - dirty: 是否待保存。
    /// - failed: 是否存在保存或恢复失败。
    /// - readOnly: 当前缓冲区是否只读。
    /// 返回：不持有磁盘访问或正文修改资格的独立呈现。
    public init(
        id: UUID,
        title: String,
        path: String?,
        selected: Bool,
        pinned: Bool,
        dirty: Bool,
        failed: Bool,
        readOnly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.selected = selected
        self.pinned = pinned
        self.dirty = dirty
        self.failed = failed
        self.readOnly = readOnly
    }

    /// 业务作用：每种保存、固定和只读状态独立可见，不让固定标记遮住未保存或失败状态。
    /// 参数说明: 无。
    /// 返回：有限且有确定顺序的状态前缀，不参与文档身份判断。
    public var statusPrefix: String {
        (failed ? "⚠ " : "") + (pinned ? "◆ " : "") + (readOnly ? "🔒 " : "") + (dirty ? "● " : "")
    }

    /// 业务作用：精确名称或路径字节变化必须刷新呈现，规范等价的 Unicode 不能留下旧路径提示。
    /// 参数说明:
    /// - lhs: 原呈现。
    /// - rhs: 待比较呈现。
    /// 返回：身份、完整字节及全部状态均相符时为真。
    public static func == (lhs: TabPresentation, rhs: TabPresentation) -> Bool {
        guard lhs.id == rhs.id, lhs.title.utf8.elementsEqual(rhs.title.utf8), lhs.selected == rhs.selected,
            lhs.pinned == rhs.pinned, lhs.dirty == rhs.dirty, lhs.failed == rhs.failed,
            lhs.readOnly == rhs.readOnly
        else {
            return false
        }
        switch (lhs.path, rhs.path) {
        case (nil, nil): return true
        case (let left?, let right?): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    /// 业务作用：标签与文档列表共享有限名称，同名时附加原目录，仍重复时按稳定身份编号。
    /// 参数说明:
    /// - tabs: 当前完整有序呈现。
    /// 返回：每个身份对应同一可读标签；只处理已有元数据，不探测或打开路径。
    public static func labels(for tabs: [TabPresentation]) -> [UUID: String] {
        let names = tabs.map {
            bounded($0.title, maximumBytes: 256)
        }
        // 显示等价的名称需要目录辅助区分；这种分组不合并原 UUID、路径或正文。
        let counts = Dictionary(
            grouping: names,
            by: {
                $0
            }
        ).mapValues(\.count)
        let bases = zip(tabs, names).map {
            tab,
            name in
            guard counts[name, default: 0] > 1 else {
                return name
            }
            let parent =
                tab.path.map {
                    ($0 as NSString).deletingLastPathComponent
                } ?? "临时文档"
            return name + " — " + bounded(parent.isEmpty ? "/" : parent, maximumBytes: 640)
        }
        let collisions = Dictionary(
            grouping: tabs.indices,
            by: {
                bases[$0]
            }
        )
        var ordinals: [UUID: Int] = [:]
        for indices in collisions.values where indices.count > 1 {
            let ordered = indices.sorted {
                tabs[$0].id.uuidString < tabs[$1].id.uuidString
            }
            for (index, source) in ordered.enumerated() {
                ordinals[tabs[source].id] = index + 1
            }
        }
        var labels: [UUID: String] = [:]
        for (index, tab) in tabs.enumerated() {
            let ordinal =
                ordinals[tab.id].map {
                    " (\($0))"
                } ?? ""
            labels[tab.id] = tab.statusPrefix + bases[index] + ordinal
        }
        return labels
    }

    /// 业务作用：界面标题保留名称两端的原始标量字节，以有限文本交给原生控件测量。
    /// 参数说明:
    /// - text: 原始名称或目录文本。
    /// - maximumBytes: 展示所用的最大 UTF-8 字节数，调用方使用固定正预算。
    /// 返回：预算内保持原文；超出时用省略号连接两端，不产生半个 UTF-8 标量。
    private static func bounded(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else {
            return text
        }
        let headCount = (maximumBytes - 3) / 2
        var head = Array(text.utf8.prefix(headCount))
        var tail = Array(text.utf8.suffix(maximumBytes - 3 - headCount))
        while String(bytes: head, encoding: .utf8) == nil {
            head.removeLast()
        }
        while String(bytes: tail, encoding: .utf8) == nil {
            tail.removeFirst()
        }
        return String(decoding: head, as: UTF8.self) + "…" + String(decoding: tail, as: UTF8.self)
    }
}
