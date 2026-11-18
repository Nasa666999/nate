import Foundation

public struct SelectionEntry: Sendable, Codable, Hashable {
    public let id: UUID
    public let selection: TextSelection

    /// 业务作用：把选区身份与几何坐标分开，光标移动不靠创建新坐标对象来表达另一项选择。
    /// 参数说明:
    /// - id: 本选区持续使用的稳定身份，新建时默认生成。
    /// - selection: 带方向和虚拟起点的真实几何。
    /// 返回：尚未绑定具体正文边界的单个选择描述。
    public init(id: UUID = UUID(), selection: TextSelection) {
        self.id = id
        self.selection = selection
    }
}

public struct SelectionState: Sendable, Equatable, Codable {
    public let entries: [SelectionEntry]
    public let primaryID: UUID
    public let shape: SelectionShape
    private let primaryIndex: Int
    public var selections: [TextSelection] {
        entries.map(\.selection)
    }
    public var primary: SelectionEntry {
        entries[primaryIndex]
    }
    public var retainedBytes: Int {
        let edges: Int
        if case .rectangle(let rectangle) = shape {
            edges = rectangle.edges.count * MemoryLayout<SelectionVirtualEdge>.stride
        }
        else {
            edges = 0
        }
        return entries.count * MemoryLayout<SelectionEntry>.stride + edges + 128
    }

    /// 业务作用：建立包含稳定身份、明确主项和完整形态的选择集合，不按文档顺序改写建立顺序。
    /// 参数说明:
    /// - entries: 当前所有选择，至少一项且最多十万项。
    /// - primaryID: 当前主选区身份，省略时使用首项。
    /// - shape: 普通流选择或具有完整逐行边缘的矩形。
    /// 返回：身份和形态一致的完整状态；非法几何、重复身份或缺失主项时失败，正文边界须另行复验。
    public init(entries: [SelectionEntry], primaryID: UUID? = nil, shape: SelectionShape = .stream) throws {
        guard !entries.isEmpty, entries.count <= 100_000,
            Set(entries.map(\.id)).count == entries.count,
            entries.allSatisfy({
                $0.selection.anchor >= 0 && $0.selection.head >= 0
                    && $0.selection.anchor != NSNotFound && $0.selection.head != NSNotFound
                    && (0...1_000_000).contains($0.selection.virtualColumn)
            }),
            let primary = primaryID ?? entries.first?.id,
            let index = entries.firstIndex(where: {
                $0.id == primary
            })
        else {
            throw NateError.message("选择集合缺少有效身份、主选区或完整范围。")
        }
        if case .rectangle(let rectangle) = shape {
            // 每行边缘必须对应现存稳定身份，缺行或重复不能作为完整矩形进入撤销与剪贴板。
            let validated = try RectangleSelectionShape(
                anchorX: rectangle.anchorX,
                headX: rectangle.headX,
                zeroWidth: rectangle.zeroWidth,
                edges: rectangle.edges,
                anchorID: rectangle.anchorID,
                headID: rectangle.headID
            )
            let edges = Dictionary(
                uniqueKeysWithValues: validated.edges.map {
                    ($0.selectionID, $0)
                }
            )
            guard edges.count == entries.count,
                entries.allSatisfy({
                    guard let edge = edges[$0.id] else {
                        return false
                    }
                    return edge.leadingColumns == $0.selection.virtualColumn
                        && (!validated.zeroWidth || $0.selection.range.isEmpty)
                })
            else {
                throw NateError.message("矩形选择与逐行虚拟边缘不一致。")
            }
        }
        self.entries = entries
        self.primaryID = primary
        self.shape = shape
        primaryIndex = index
    }

    /// 业务作用：为新建立的普通选择一次分配稳定身份，不改变传入的建立顺序或方向。
    /// 参数说明:
    /// - selections: 完整原始几何。
    /// - primaryIndex: 主选区在原始数组中的位置。
    /// 返回：新的普通选择集合；空集合、非法主项或容量超限时失败。
    public init(selections: [TextSelection], primaryIndex: Int = 0) throws {
        guard selections.count <= 100_000, selections.indices.contains(primaryIndex) else {
            throw NateError.invalidRange
        }
        let entries = selections.map {
            SelectionEntry(selection: $0)
        }
        try self.init(entries: entries, primaryID: entries[primaryIndex].id)
    }

    /// 业务作用：恢复选择时重新验证身份和完整形态，解码不能绕过普通构造的容量与主项门禁。
    /// 参数说明:
    /// - decoder: 已由所属存储限制原始数据容量的解码器。
    /// 返回：合法完整集合；超量、重复身份、缺失主项或不完整矩形时失败。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var values = try container.nestedUnkeyedContainer(forKey: .entries)
        guard
            values.count.map({
                $0 <= 100_000
            }) ?? true
        else {
            throw NateError.message("恢复选择超过十万项。")
        }
        var entries: [SelectionEntry] = []
        while !values.isAtEnd {
            guard entries.count < 100_000 else {
                throw NateError.message("恢复选择超过十万项。")
            }
            entries.append(try values.decode(SelectionEntry.self))
        }
        try self.init(
            entries: entries,
            primaryID: container.decode(UUID.self, forKey: .primaryID),
            shape: container.decodeIfPresent(SelectionShape.self, forKey: .shape) ?? .stream
        )
    }

    /// 业务作用：只保存真实选择身份、主项和形态，不把派生数组索引作为恢复权限。
    /// 参数说明:
    /// - encoder: 所属存储提供的编码器。
    /// 返回：可由同一验证入口恢复的完整状态。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(primaryID, forKey: .primaryID)
        try container.encode(shape, forKey: .shape)
    }

    private enum CodingKeys: String, CodingKey {
        case entries, primaryID, shape
    }
}
