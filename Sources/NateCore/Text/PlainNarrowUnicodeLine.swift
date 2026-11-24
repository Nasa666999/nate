import Foundation

public struct PlainNarrowUnicodeLine: Sendable {
    public let range: ByteRange
    public let characterCount: Int
    public let scalars: [UInt16]
    private let text: PieceTree
    private let sourceIdentity: UUID

    private enum UnsupportedText: Error {
        case scalar
    }

    /// 业务作用：确认超长行只包含独立的左到右字母和可打印 ASCII，为字体测量提供实际出现的标量。
    /// 参数说明:
    /// - source: 当前文档的不可变正文。
    /// - range: 当前物理行排除原始结束符的范围。
    /// - deadline: 此行与所属窗口准备共用的截止。
    /// 返回：可安全测量的实际字符集及原字节索引；遇到组合字符、方向控制、Tab 或不支持的标量时为空。
    public init?(text source: PieceTree, range: ByteRange, deadline: ContinuousClock.Instant) throws {
        guard range.lower >= 0, range.upper > range.lower, range.upper <= source.byteCount,
            range.count <= ASCIITabColumns.maximumBytes, source.isBoundary(range.lower),
            source.isBoundary(range.upper)
        else {
            return nil
        }
        let text = try source.slicing(range)
        guard text.utf16Count < text.byteCount else {
            return nil
        }
        var encountered: Set<UInt16> = []
        do {
            try text.forEachChunk(maximumBytes: 65_536) { chunk in
                try Self.check(deadline)
                if chunk.tree.isPrintableASCII(in: ByteRange(0, chunk.byteCount)) {
                    return
                }
                let raw = chunk.bytes()
                var index = 0
                while index < raw.count {
                    let first = raw[index]
                    if (32...126).contains(first) {
                        index += 1
                        continue
                    }
                    // 字符集只使用两个 UTF-8 字节的独立字母，避免把代理项、组合附标或控制字符拆成可见列。
                    guard (194...223).contains(first), index + 1 < raw.count else {
                        throw UnsupportedText.scalar
                    }
                    let scalar = UInt16(first & 31) << 6 | UInt16(raw[index + 1] & 63)
                    guard Self.contains(scalar) else {
                        throw UnsupportedText.scalar
                    }
                    encountered.insert(scalar)
                    index += 2
                }
            }
        }
        catch UnsupportedText.scalar {
            return nil
        }
        try Self.check(deadline)
        self.text = text
        sourceIdentity = source.sourceIdentity
        self.range = range
        characterCount = text.utf16Count
        scalars = encountered.sorted()
    }

    /// 业务作用：只采用具有独立单元和左到右语义的拉丁、希腊及西里尔字母范围。
    /// 参数说明:
    /// - scalar: 已由真实 UTF-8 原字节取得的单个 Unicode 标量。
    /// 返回：属于固定候选范围时为真，实际字体度量仍需单独确认。
    private static func contains(_ scalar: UInt16) -> Bool {
        if (0x00C0...0x017F).contains(scalar) {
            return scalar != 0x00D7 && scalar != 0x00F7
        }
        return scalar == 0x0386
            || (0x0388...0x038A).contains(scalar)
            || scalar == 0x038C
            || (0x038E...0x03A1).contains(scalar)
            || (0x03A3...0x03CE).contains(scalar)
            || (0x0400...0x0481).contains(scalar)
    }

    /// 业务作用：资格检查和实际原文字体投影必须来自同一不可变根。
    /// 参数说明:
    /// - source: 当前请求的原正文。
    /// 返回：该源仍为建立字符证据的固定树时为真。
    public func matches(_ source: PieceTree) -> Bool {
        sourceIdentity == source.sourceIdentity
    }

    /// 业务作用：由已确认的独立字符取窗口边界，避免把两个字节的字母切成无效 UTF-8。
    /// 参数说明:
    /// - character: 完整逻辑行相对的 UTF-16 端点。
    /// 返回：正文内的绝对原字节；非法端点为空。
    public func byte(at character: Int) -> Int? {
        text.byteOffset(utf16: character).map { range.lower + $0 }
    }

    /// 业务作用：输入位置由完整原始标量换算为逻辑列，每个受支持字母只占一个编辑列。
    /// 参数说明:
    /// - byte: 完整正文中的真实 UTF-8 端点。
    /// 返回：相对本行起点的字符数；越界或半个原标量为空。
    func character(atByte byte: Int) -> Int? {
        guard (range.lower...range.upper).contains(byte) else {
            return nil
        }
        return text.utf16Offset(byte: byte - range.lower)
    }

    /// 业务作用：后台扫描没有完整资格时不发布部分长行测量。
    /// 参数说明:
    /// - deadline: 准备动作的共同截止。
    /// 返回：在实际许可和时限内继续，失效时结束工作。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("超长等宽 Unicode 行测量超过五秒预算。")
        }
    }
}
