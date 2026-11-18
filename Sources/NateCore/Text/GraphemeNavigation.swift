import Foundation

private enum GraphemeClass: UInt8 {
    case other, cr, lf, control, extend, joiner, regional, prepend, spacing, l, v, t, lv, lvt
}

private struct GraphemeScalar {
    let lower: Int
    let upper: Int
    let flags: UInt8
    var kind: GraphemeClass {
        GraphemeClass(rawValue: flags & 15) ?? .other
    }
    var conjunct: UInt8 {
        (flags >> 4) & 3
    }
    var pictographic: Bool {
        flags & 0x40 != 0
    }
    var control: Bool {
        kind == .cr || kind == .lf || kind == .control
    }
}

public struct GraphemeNavigation {
    public static let unicodeVersion = "17.0.0"
    private let text: PieceTree
    private let scalarLimit: Int
    private var remaining: Int
    private let deadline: ContinuousClock.Instant

    /// 业务作用：为同一次多光标移动、删除或覆盖建立共享读取预算，不复制完整逻辑行。
    /// 参数说明:
    /// - text: 本次动作固定的原始正文。
    /// - maximumScalars: 本次动作合计允许的标量读取次数，必须在一至 262144 之间。
    /// 返回：固定 Unicode 17.0.0 的扩展字形簇导航器；非法预算失败，动作共用一百毫秒截止。
    public init(text: PieceTree, maximumScalars: Int = 262_144) throws {
        guard maximumScalars > 0, maximumScalars <= 262_144 else {
            throw NateError.message("字形簇读取预算必须在 1 至 262144 之间。")
        }
        self.text = text
        scalarLimit = maximumScalars
        remaining = maximumScalars
        deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    }

    /// 业务作用：沿真实源标量寻找严格相邻的完整扩展字形簇边界，组合、旗帜和连写不能被部分删除。
    /// 参数说明:
    /// - offset: 当前正文中合法的 UTF-8 标量边界，可以位于一个字形簇内部。
    /// - forward: 为真时寻找右侧边界，否则寻找左侧边界。
    /// 返回：文档端点保持不变；非法位置、取消或共享预算不足整体失败，不返回近似或截断边界。
    public mutating func boundary(from offset: Int, forward: Bool) throws -> Int {
        guard text.isBoundary(offset) else {
            throw NateError.invalidRange
        }
        try checkpoint()
        if forward {
            guard offset < text.byteCount else {
                return offset
            }
            var position = try starting(at: offset).upper
            while position < text.byteCount {
                if try breaks(at: position) {
                    return position
                }
                position = try starting(at: position).upper
            }
            return text.byteCount
        }
        guard offset > 0 else {
            return offset
        }
        var position = try ending(at: offset).lower
        while position > 0 {
            if try breaks(at: position) {
                return position
            }
            position = try ending(at: position).lower
        }
        return 0
    }

    /// 业务作用：删除与覆盖光标处的完整字形簇，外部搜索形成的簇内光标同样不能切断组合内容。
    /// 参数说明:
    /// - offset: 当前正文中合法的 UTF-8 标量边界。
    /// - forward: 在完整簇边界时选择右侧字形，否则选择左侧字形；簇内位置统一选择所在完整簇。
    /// 返回：完整原文范围，文档端点可能为空；无法取得两侧证据时整体失败，不发布部分范围。
    public mutating func range(at offset: Int, forward: Bool) throws -> ByteRange {
        guard text.isBoundary(offset) else {
            throw NateError.invalidRange
        }
        if offset > 0 && offset < text.byteCount, try !breaks(at: offset) {
            return ByteRange(
                try boundary(from: offset, forward: false),
                try boundary(from: offset, forward: true)
            )
        }
        let adjacent = try boundary(from: offset, forward: forward)
        return ByteRange(min(offset, adjacent), max(offset, adjacent))
    }

    /// 业务作用：按有序扩展字形簇规则复验一个内部标量边界，必要上下文始终读取原文而不归一化。
    /// 参数说明:
    /// - position: 文档内部的合法标量边界。
    /// 返回：可以在此分段为真；无法取得完整上下文时失败，不能猜测安全删除范围。
    private mutating func breaks(at position: Int) throws -> Bool {
        let left = try ending(at: position)
        let right = try starting(at: position)
        if left.kind == .cr && right.kind == .lf {
            return false
        }
        if left.control || right.control {
            return true
        }
        if left.kind == .l && [.l, .v, .lv, .lvt].contains(right.kind) {
            return false
        }
        if [.lv, .v].contains(left.kind) && [.v, .t].contains(right.kind) {
            return false
        }
        if [.lvt, .t].contains(left.kind) && right.kind == .t {
            return false
        }
        if [.extend, .joiner, .spacing].contains(right.kind) || left.kind == .prepend {
            return false
        }
        if right.conjunct == 1 {
            var cursor = left
            var linked = false
            while cursor.conjunct == 2 || cursor.conjunct == 3 {
                linked = linked || cursor.conjunct == 3
                guard cursor.lower > 0 else {
                    return true
                }
                cursor = try ending(at: cursor.lower)
            }
            if linked && cursor.conjunct == 1 {
                return false
            }
        }
        if left.kind == .joiner && right.pictographic {
            var position = left.lower
            while position > 0 {
                let previous = try ending(at: position)
                if previous.kind != .extend {
                    return !previous.pictographic
                }
                position = previous.lower
            }
        }
        if left.kind == .regional && right.kind == .regional {
            var count = 1
            var position = left.lower
            while position > 0 {
                let previous = try ending(at: position)
                guard previous.kind == .regional else {
                    break
                }
                count += 1
                position = previous.lower
            }
            return count % 2 == 0
        }
        return true
    }

    /// 业务作用：只解码需要判断的一个源标量，跨文本叶片时仍使用真实 UTF-8 字节。
    /// 参数说明:
    /// - position: 合法标量起点，不能是文末。
    /// 返回：原文起止及固定分段属性；预算、编码或范围不完整时失败。
    private mutating func starting(at position: Int) throws -> GraphemeScalar {
        try checkpoint()
        guard remaining > 0 else {
            throw NateError.message("字形簇上下文超过 \(scalarLimit) 次标量读取预算，操作未执行。")
        }
        remaining -= 1
        guard let first = text.byte(at: position) else {
            throw NateError.invalidRange
        }
        let width = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
        var scalar = UInt32(first & (width == 1 ? 0x7F : width == 2 ? 0x1F : width == 3 ? 0x0F : 0x07))
        for index in 1..<width {
            guard let byte = text.byte(at: position + index) else {
                throw NateError.invalidRange
            }
            scalar = scalar << 6 | UInt32(byte & 0x3F)
        }
        return GraphemeScalar(
            lower: position,
            upper: position + width,
            flags: GraphemePropertyData.properties(scalar)
        )
    }

    /// 业务作用：从标量右边界反向解码，最多检查四个源字节，不建立反向正文副本。
    /// 参数说明:
    /// - position: 合法标量右边界，不能是文首。
    /// 返回：紧邻左侧的完整标量；非法位置或预算不足失败。
    private mutating func ending(at position: Int) throws -> GraphemeScalar {
        guard position > 0 else {
            throw NateError.invalidRange
        }
        var start = position - 1
        while !text.isBoundary(start) {
            start -= 1
        }
        return try starting(at: start)
    }

    /// 业务作用：所有方向与上下文回看共用取消和截止，证据不足时不允许发布部分多光标动作。
    /// 参数说明: 无。
    /// 返回：仍在本次交互预算内时继续，否则明确失败。
    private func checkpoint() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("字形簇上下文超过一百毫秒预算，操作未执行。")
        }
    }
}
