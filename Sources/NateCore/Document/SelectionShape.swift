import Foundation

public struct SelectionVirtualEdge: Sendable, Codable, Equatable {
    public let selectionID: UUID
    public let leadingColumns: Int
    public let trailingColumns: Int
    public let projection: RectangleEditProjection?

    /// 业务作用：分别保留短行列起点和被选中的行尾虚拟空白，复制矩形时不把定位空白误当成正文。
    /// 参数说明:
    /// - selectionID: 对应的稳定行内选区身份。
    /// - leadingColumns: 空光标位于真实行尾之后的起始空白列。
    /// - trailingColumns: 这行实际被选中的额外虚拟空白列。
    /// - projection: 可选的原生实际字节范围和边缘 Tab 保留列数。
    /// 返回：不写入任何空格的形态描述；负值或超过一百万列时失败。
    public init(
        selectionID: UUID,
        leadingColumns: Int = 0,
        trailingColumns: Int = 0,
        projection: RectangleEditProjection? = nil
    ) throws {
        guard (0...1_000_000).contains(leadingColumns), (0...1_000_000).contains(trailingColumns) else {
            throw NateError.message("矩形虚拟边缘最多一百万列，不能截断或解释为实际正文。")
        }
        self.selectionID = selectionID
        self.leadingColumns = leadingColumns
        self.trailingColumns = trailingColumns
        self.projection = projection
    }

    /// 业务作用：外部选择记录的虚拟边缘仍经过列数门禁，解码不能取得无限空白分配资格。
    /// 参数说明:
    /// - decoder: 所属存储限制了原始容量的解码器。
    /// 返回：合法的稳定行身份与虚拟边缘；非法列数时失败。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            selectionID: container.decode(UUID.self, forKey: .selectionID),
            leadingColumns: container.decode(Int.self, forKey: .leadingColumns),
            trailingColumns: container.decode(Int.self, forKey: .trailingColumns),
            projection: container.decodeIfPresent(RectangleEditProjection.self, forKey: .projection)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case selectionID, leadingColumns, trailingColumns, projection
    }
}

public struct RectangleSelectionShape: Sendable, Codable, Equatable {
    public let anchorX: Double
    public let headX: Double
    public let zeroWidth: Bool
    public let edges: [SelectionVirtualEdge]
    public let anchorID: UUID?
    public let headID: UUID?
    public let layoutContext: RectangleLayoutContext?
    public let needsRevalidation: Bool
    public let hasCompleteProjections: Bool

    /// 业务作用：保留与当前视图字体绑定的矩形横向意图及每行虚拟边缘，不把像素当成字节列。
    /// 参数说明:
    /// - anchorX: 相对正文左边缘的固定视觉横坐标。
    /// - headX: 相对正文左边缘的活动视觉横坐标。
    /// - zeroWidth: 交互明确确认的零宽模式，独立于实际空范围。
    /// - edges: 每个稳定行选区的完整虚拟边缘。
    /// - anchorID: 可选的固定行身份，与活动行身份一并提供。
    /// - headID: 可选的活动行身份，独立于后来切换的主选区角色。
    /// - layoutContext: 原生视觉边缘的字体、宽度和样式证据，纯逻辑调用方可不提供。
    /// - needsRevalidation: 正文映射后保留原形态但暂停视觉编辑，必须由用户重新选择边缘。
    /// 返回：最多十万行的完整矩形形态；非法像素、重复行身份或容量超限时失败。
    public init(
        anchorX: Double,
        headX: Double,
        zeroWidth: Bool,
        edges: [SelectionVirtualEdge],
        anchorID: UUID? = nil,
        headID: UUID? = nil,
        layoutContext: RectangleLayoutContext? = nil,
        needsRevalidation: Bool = false
    ) throws {
        guard anchorX.isFinite, headX.isFinite, (0...1_000_000_000).contains(anchorX),
            (0...1_000_000_000).contains(headX), !edges.isEmpty, edges.count <= 100_000,
            Set(edges.map(\.selectionID)).count == edges.count,
            edges.allSatisfy({
                (0...1_000_000).contains($0.leadingColumns)
                    && (0...1_000_000).contains($0.trailingColumns)
                    && (!zeroWidth || $0.trailingColumns == 0)
            })
        else {
            throw NateError.message("矩形形态无效，未把部分行边缘作为完整选择。")
        }
        let identities = Set(edges.map(\.selectionID))
        guard (anchorID == nil) == (headID == nil),
            anchorID.map({
                identities.contains($0)
            }) ?? true,
            headID.map({
                identities.contains($0)
            }) ?? true
        else {
            throw NateError.message("矩形固定行和活动行必须同时对应现存选择。")
        }
        self.anchorX = anchorX
        self.headX = headX
        self.zeroWidth = zeroWidth
        self.edges = edges
        self.anchorID = anchorID
        self.headID = headID
        self.layoutContext = layoutContext
        self.needsRevalidation = needsRevalidation
        hasCompleteProjections = edges.allSatisfy {
            $0.projection != nil
        }
    }

    /// 业务作用：矩形恢复必须完整验证视觉位置和逐行边缘，超量输入不先构建全部行对象。
    /// 参数说明:
    /// - decoder: 所属存储限制原始容量的解码器。
    /// 返回：与普通构造同样受限的完整形态；缺行、重复身份或非法像素时失败。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var values = try container.nestedUnkeyedContainer(forKey: .edges)
        guard
            values.count.map({
                $0 <= 100_000
            }) ?? true
        else {
            throw NateError.message("矩形恢复超过十万行。")
        }
        var edges: [SelectionVirtualEdge] = []
        while !values.isAtEnd {
            guard edges.count < 100_000 else {
                throw NateError.message("矩形恢复超过十万行。")
            }
            edges.append(try values.decode(SelectionVirtualEdge.self))
        }
        try self.init(
            anchorX: container.decode(Double.self, forKey: .anchorX),
            headX: container.decode(Double.self, forKey: .headX),
            zeroWidth: container.decode(Bool.self, forKey: .zeroWidth),
            edges: edges,
            anchorID: container.decodeIfPresent(UUID.self, forKey: .anchorID),
            headID: container.decodeIfPresent(UUID.self, forKey: .headID),
            layoutContext: container.decodeIfPresent(RectangleLayoutContext.self, forKey: .layoutContext),
            needsRevalidation: container.decodeIfPresent(Bool.self, forKey: .needsRevalidation) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case anchorX, headX, zeroWidth, edges, anchorID, headID, layoutContext, needsRevalidation
    }
}

public enum SelectionShape: Sendable, Codable, Equatable {
    case stream
    case rectangle(RectangleSelectionShape)
}
