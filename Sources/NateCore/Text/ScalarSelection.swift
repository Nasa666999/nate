import Foundation

public enum WordSelection: Sendable, Equatable {
    case word(ByteRange)
    case noWord
    case exceedsLimit
}

extension PieceTree {
    /// 业务作用：有界统计连续选区的 Unicode 标量数，为字符阈值判断避免读取巨型选区全文。
    /// 参数说明:
    /// - range: 当前快照中完整标量边界的连续选区。
    /// - limit: 判断所需的最大数量，达到后立即停止，零表示无需计数。
    /// 返回：实际标量数与上限的较小值；非法范围或负上限失败，CR 和 LF 分别计数。
    public func boundedScalarCount(in range: ByteRange, limit: Int) throws -> Int {
        guard limit >= 0, range.lower <= range.upper,
            isBoundary(range.lower), isBoundary(range.upper)
        else {
            throw NateError.invalidRange
        }
        guard limit > 0, !range.isEmpty else {
            return 0
        }
        // 一个标量至多占两个 UTF-16 单元；达到两倍阈值足以证明字符数量达标，不把单元数当作字符数。
        if limit <= Int.max / 2,
            let first = utf16Offset(byte: range.lower), let last = utf16Offset(byte: range.upper),
            last - first >= limit * 2
        {
            return limit
        }
        var count = 0
        var position = range.lower
        while position < range.upper, count < limit, let first = byte(at: position) {
            position += first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
            count += 1
        }
        return count
    }

    /// 业务作用：围绕光标完整定位单词，超过自动填入预算时不返回截断词，也不复制整行。
    /// 参数说明:
    /// - position: 合法标量边界的光标位置，位于词尾时允许选择前一个词。
    /// - maximumScalars: 整个单词允许的最大标量数量。
    /// 返回：字母、数字、组合标记和下划线组成的完整范围；无单词、无效位置或超限为空。
    public func wordRange(at position: Int, maximumScalars: Int) -> ByteRange? {
        if case .word(let range) = wordSelection(at: position, maximumScalars: maximumScalars) {
            return range
        }
        return nil
    }

    /// 业务作用：向交互入口区分完整单词、非单词位置和预算不足，容量提示不误报为不存在单词。
    /// 参数说明:
    /// - position: 当前快照的合法标量边界。
    /// - maximumScalars: 整词的最大标量数量。
    /// 返回：完整单词范围、无单词或明确超限；无效位置和非正预算不生成范围。
    public func wordSelection(at position: Int, maximumScalars: Int) -> WordSelection {
        guard maximumScalars > 0, isBoundary(position) else {
            return .noWord
        }
        var lower = position
        var count = 0
        while lower > 0 {
            var previous = lower - 1
            while !isBoundary(previous) {
                previous -= 1
            }
            guard let scalar = scalarStarting(at: previous), Self.isWordScalar(scalar.value) else {
                break
            }
            guard count < maximumScalars else {
                return .exceedsLimit
            }
            count += 1
            lower = previous
        }
        var upper = position
        while let scalar = scalarStarting(at: upper), Self.isWordScalar(scalar.value) {
            guard count < maximumScalars else {
                return .exceedsLimit
            }
            count += 1
            upper += scalar.width
        }
        return lower < upper ? .word(ByteRange(lower, upper)) : .noWord
    }

    /// 业务作用：只解码当前位置的一个标量，单词边界检查不建立段落或全文副本。
    /// 参数说明:
    /// - position: 已确认的标量边界。
    /// 返回：正文中的标量与其 UTF-8 宽度；文档末端为空。
    private func scalarStarting(at position: Int) -> (value: Unicode.Scalar, width: Int)? {
        guard let first = byte(at: position) else {
            return nil
        }
        let width = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
        var value = UInt32(first & (width == 1 ? 0x7F : width == 2 ? 0x1F : width == 3 ? 0x0F : 0x07))
        if width > 1 {
            for index in 1..<width {
                guard let next = byte(at: position + index) else {
                    return nil
                }
                value = (value << 6) | UInt32(next & 0x3F)
            }
        }
        return Unicode.Scalar(value).map {
            (value: $0, width: width)
        }
    }

    /// 业务作用：单词填入使用固定 Unicode 17.0.0 分类，与搜索整词边界一致且不依赖系统库版本。
    /// 参数说明:
    /// - scalar: 当前正文标量。
    /// 返回：字母、数字、组合标记或 ASCII 下划线为真，其它标点和空白为假。
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        UnicodeWordClassification.contains(scalar.value)
    }
}
