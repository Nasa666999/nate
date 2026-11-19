import CryptoKit
import Foundation

public enum SelectionStateArchive {
    public static let maximumBytes = 6 * 1024 * 1024

    /// 业务作用：用有界紧凑协议保存十万项的稳定身份、主项、方向和矩形证据，不重复保存 UUID 文本。
    /// 参数说明:
    /// - state: 已由所属正文验证的完整不可变选择。
    /// - permit: 本次完整保存仍有执行资格。
    /// 返回：含整份 SHA-256 的归档；取消、超量或非法字段时不提供部分内容。
    public static func encode(
        _ state: SelectionState,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        let indices = Dictionary(
            uniqueKeysWithValues: state.entries.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        guard let primary = indices[state.primaryID] else {
            throw NateError.invalidRange
        }
        let rectangle: RectangleSelectionShape?
        if case .rectangle(let shape) = state.shape {
            rectangle = shape
        }
        else {
            rectangle = nil
        }
        var writer = SelectionArchiveWriter(budget: budget)
        try writer.append(Data("NATESELS".utf8))
        writer.unsigned(UInt16(1))
        writer.unsigned(UInt8(rectangle == nil ? 0 : 1))
        writer.unsigned(
            UInt8((rectangle?.zeroWidth == true ? 1 : 0) | (rectangle?.needsRevalidation == true ? 2 : 0))
        )
        writer.unsigned(UInt32(state.entries.count))
        writer.unsigned(UInt32(primary))
        var edges: [UUID: (Int, SelectionVirtualEdge)] = [:]
        if let rectangle {
            writer.unsigned(rectangle.anchorX.bitPattern)
            writer.unsigned(rectangle.headX.bitPattern)
            writer.unsigned(
                rectangle.anchorID.flatMap {
                    indices[$0]
                }.map(UInt32.init) ?? UInt32.max
            )
            writer.unsigned(
                rectangle.headID.flatMap {
                    indices[$0]
                }.map(UInt32.init) ?? UInt32.max
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let context =
                try rectangle.layoutContext.map {
                    try encoder.encode($0)
                } ?? Data()
            guard context.count <= 8192 else {
                throw NateError.message("矩形布局上下文超过 8 KiB。")
            }
            writer.unsigned(UInt32(context.count))
            try writer.append(context)
            edges = Dictionary(
                uniqueKeysWithValues: rectangle.edges.enumerated().map {
                    ($0.element.selectionID, ($0.offset, $0.element))
                }
            )
        }
        for (index, entry) in state.entries.enumerated() {
            if index & 255 == 0 {
                try budget.check()
            }
            try writer.append(
                withUnsafeBytes(of: entry.id.uuid) {
                    Data($0)
                }
            )
            try writer.coordinate(entry.selection.anchor)
            try writer.coordinate(entry.selection.head)
            try writer.coordinate(entry.selection.virtualColumn)
            if rectangle != nil {
                guard let (rank, edge) = edges[entry.id] else {
                    throw NateError.invalidRange
                }
                writer.unsigned(UInt32(rank))
                try writer.coordinate(edge.trailingColumns)
                writer.unsigned(UInt8(edge.projection == nil ? 0 : 1))
                if let projection = edge.projection {
                    try writer.coordinate(projection.range.lower)
                    try writer.coordinate(projection.range.upper)
                    try writer.coordinate(projection.leadingSpaces)
                    try writer.coordinate(projection.trailingSpaces)
                }
            }
        }
        try budget.check()
        let digest = Data(SHA256.hash(data: writer.data))
        try writer.append(digest)
        return writer.data
    }

    /// 业务作用：完整选择先核对协议、容量和摘要，再一次恢复原身份，未知格式不能静默退化为普通光标。
    /// 参数说明:
    /// - data: 从所属有界存储取得的完整原始归档。
    /// - permit: 当前仍有完整恢复资格。
    /// 返回：身份与形态完整的状态，所属正文仍须复验；未知格式、截断、重复身份或超量时失败。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> SelectionState {
        let budget = SelectionPreparationBudget(permit: permit)
        try budget.check()
        guard (80...maximumBytes).contains(data.count) else {
            throw NateError.message("完整选择归档长度无效或超过 6 MiB。")
        }
        let body = Data(data.dropLast(32))
        let digest = Data(SHA256.hash(data: body))
        try budget.check()
        guard digest.elementsEqual(data.suffix(32)) else {
            throw NateError.message("完整选择归档摘要不一致，原记录保留。")
        }
        var reader = SelectionArchiveReader(data: body, budget: budget)
        guard try reader.bytes(8) == Data("NATESELS".utf8), try reader.unsigned(UInt16.self) == 1 else {
            throw SelectionArchiveError.unsupportedFormat
        }
        let kind = try reader.unsigned(UInt8.self), flags = try reader.unsigned(UInt8.self)
        guard kind <= 1, flags <= 3, kind == 1 || flags == 0 else {
            throw SelectionArchiveError.unsupportedFormat
        }
        let count = Int(try reader.unsigned(UInt32.self)), primary = Int(try reader.unsigned(UInt32.self))
        guard (1...100_000).contains(count), primary < count,
            count <= (body.count - reader.cursor) / (kind == 0 ? 28 : 37)
        else {
            throw NateError.message("完整选择归档的数量或主项无效。")
        }
        var anchorX = 0.0, headX = 0.0
        var anchor: UInt32 = .max, head: UInt32 = .max
        var context: RectangleLayoutContext?
        if kind == 1 {
            anchorX = Double(bitPattern: try reader.unsigned(UInt64.self))
            headX = Double(bitPattern: try reader.unsigned(UInt64.self))
            anchor = try reader.unsigned(UInt32.self)
            head = try reader.unsigned(UInt32.self)
            guard (anchor == .max && head == .max) || (anchor < count && head < count) else {
                throw NateError.invalidRange
            }
            let size = Int(try reader.unsigned(UInt32.self))
            guard size <= 8192 else {
                throw NateError.message("矩形布局上下文超过 8 KiB。")
            }
            if size > 0 {
                let data = try reader.bytes(size)
                let keys: Set<String> = [
                    "fontName", "pointSize", "fontTraits", "layoutWidth", "rightToLeft", "styleIdentity",
                ]
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    Set(object.keys) == keys
                else {
                    throw SelectionArchiveError.unsupportedFormat
                }
                context = try JSONDecoder().decode(RectangleLayoutContext.self, from: data)
            }
        }
        var entries: [SelectionEntry] = []
        var edges = [SelectionVirtualEdge?](repeating: nil, count: kind == 1 ? count : 0)
        var identities: Set<UUID> = []
        for index in 0..<count {
            if index & 255 == 0 {
                try budget.check()
            }
            let bytes = [UInt8](try reader.bytes(16))
            let id = UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                    bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
            guard identities.insert(id).inserted else {
                throw NateError.message("完整选择归档包含重复身份。")
            }
            let selection = try TextSelection(
                anchor: reader.coordinate(),
                head: reader.coordinate(),
                virtualColumn: reader.coordinate()
            )
            entries.append(SelectionEntry(id: id, selection: selection))
            if kind == 1 {
                let rank = Int(try reader.unsigned(UInt32.self)), tail = try reader.coordinate()
                let projected = try reader.unsigned(UInt8.self)
                guard rank < count, edges[rank] == nil, projected <= 1 else {
                    throw NateError.message("矩形边缘顺序或投影字段无效。")
                }
                let projection: RectangleEditProjection?
                if projected == 1 {
                    projection = try RectangleEditProjection(
                        range: ByteRange(reader.coordinate(), reader.coordinate()),
                        leadingSpaces: reader.coordinate(),
                        trailingSpaces: reader.coordinate()
                    )
                }
                else {
                    projection = nil
                }
                edges[rank] = try SelectionVirtualEdge(
                    selectionID: id,
                    leadingColumns: selection.virtualColumn,
                    trailingColumns: tail,
                    projection: projection
                )
            }
        }
        guard reader.cursor == body.count else {
            throw NateError.message("完整选择归档包含未知尾部，原记录保留。")
        }
        let shape: SelectionShape
        if kind == 1 {
            shape = .rectangle(
                try RectangleSelectionShape(
                    anchorX: anchorX,
                    headX: headX,
                    zeroWidth: flags & 1 != 0,
                    edges: edges.compactMap {
                        $0
                    },
                    anchorID: anchor == .max ? nil : entries[Int(anchor)].id,
                    headID: head == .max ? nil : entries[Int(head)].id,
                    layoutContext: context,
                    needsRevalidation: flags & 2 != 0
                )
            )
        }
        else {
            shape = .stream
        }
        try budget.check()
        let state = try SelectionState(entries: entries, primaryID: entries[primary].id, shape: shape)
        try budget.check()
        return state
    }
}
