import Foundation

public struct PlainCombiningLine: Sendable {
    public let range: ByteRange
    public let characterCount: Int
    public let cellCount: Int
    public let independentScalars: [UInt16]
    public let combiningPairs: [UInt32]
    public let tabWidth: Int?

    private struct Position: Sendable {
        var byte = 0
        var character = 0
        var cell = 0
    }

    private enum Qualification: Error {
        case unsupported
    }

    private static let interval = 2048
    private static let pairs: Set<UInt32> = Set(
        (UInt32(0xC0)...UInt32(0x17F)).compactMap { scalar in
            guard let scalar = UnicodeScalar(scalar) else {
                return nil
            }
            let units = Array(String(scalar).decomposedStringWithCanonicalMapping.utf16)
            guard units.count == 2,
                (65...90).contains(units[0]) || (97...122).contains(units[0]),
                [0x300, 0x301, 0x302, 0x303, 0x308, 0x30A, 0x327].contains(units[1])
            else {
                return nil
            }
            return UInt32(units[0]) << 16 | UInt32(units[1])
        }
    )

    private let text: PieceTree
    private let sourceIdentity: UUID
    private let checkpoints: [Position]

    /// 业务作用：确认拉丁字母及单个可组合附标的原文，用稀疏边界索引保留完整字形、UTF-16 和原字节。
    /// 参数说明:
    /// - source: 当前视图的固定原文。
    /// - range: 不含物理结束符的完整逻辑行。
    /// - tabWidth: 当前语言采用的实际制表间隔。
    /// - deadline: 此行原文及其它排版资格检查共用的截止。
    /// 返回：全部单元可定位且确实含组合字形时交付索引。未知组合或方向控制不取得资格。
    public init?(
        text source: PieceTree,
        range: ByteRange,
        tabWidth: Int = 4,
        deadline: ContinuousClock.Instant
    ) throws {
        guard range.lower >= 0, range.upper > range.lower, range.upper <= source.byteCount,
            range.count <= ASCIITabColumns.maximumBytes, source.isBoundary(range.lower),
            source.isBoundary(range.upper), (1...32).contains(tabWidth)
        else {
            return nil
        }
        let text = try source.slicing(range)
        guard text.byteCount > text.utf16Count else {
            return nil
        }
        var position = Position()
        var checkpoints = [position]
        var independent: Set<UInt16> = []
        var combinations: Set<UInt32> = []
        var precedingASCII: UInt8?
        var glyphs = 0
        var containsTab = false
        do {
            try text.forEachChunk(maximumBytes: 65_536) { chunk in
                try Self.check(deadline)
                let bytes = chunk.bytes()
                var offset = 0
                while offset < bytes.count {
                    let leading = bytes[offset]
                    let ascii = (32...126).contains(leading)
                    let tab = leading == 9
                    let size = ascii || tab ? 1 : 2
                    if size == 2, (!(194...223).contains(leading) || offset + 1 >= bytes.count) {
                        throw Qualification.unsupported
                    }
                    if leading == 204 {
                        // 分块可以落在附标前。只有与上一原始 ASCII 字母组成已知字形时，附标才共享其编辑列。
                        let mark = UInt16(leading & 31) << 6 | UInt16(bytes[offset + 1] & 63)
                        guard let precedingASCII else {
                            throw Qualification.unsupported
                        }
                        let pair = UInt32(precedingASCII) << 16 | UInt32(mark)
                        guard Self.pairs.contains(pair) else {
                            throw Qualification.unsupported
                        }
                        combinations.insert(pair)
                    }
                    else {
                        if size == 2 {
                            let scalar = UInt16(leading & 31) << 6 | UInt16(bytes[offset + 1] & 63)
                            guard PlainNarrowUnicodeLine.contains(scalar) else {
                                throw Qualification.unsupported
                            }
                            independent.insert(scalar)
                        }
                        if glyphs > 0, glyphs.isMultiple(of: Self.interval) {
                            checkpoints.append(position)
                        }
                        containsTab = containsTab || tab
                        position.cell += ASCIITabColumns.advance(
                            for: leading,
                            from: position.cell,
                            tabWidth: tabWidth
                        )
                        glyphs += 1
                    }
                    precedingASCII = ascii ? leading : nil
                    offset += size
                    position.byte += size
                    position.character += 1
                }
            }
        }
        catch Qualification.unsupported {
            return nil
        }
        try Self.check(deadline)
        guard !combinations.isEmpty else {
            return nil
        }
        checkpoints.append(position)
        self.text = text
        self.range = range
        sourceIdentity = source.sourceIdentity
        characterCount = position.character
        cellCount = position.cell
        independentScalars = independent.sorted()
        combiningPairs = combinations.sorted()
        self.tabWidth = containsTab ? tabWidth : nil
        self.checkpoints = checkpoints
    }

    /// 业务作用：排版与编辑只接受同一原文根及实际制表网格的组合字形证据。
    /// 参数说明:
    /// - source: 当前视图或编辑请求使用的完整正文。
    /// - width: 当前语言采用的真实制表列数。
    /// 返回：原文及实际使用的制表网格一致时为真。
    public func matches(_ source: PieceTree, tabWidth width: Int = 4) -> Bool {
        sourceIdentity == source.sourceIdentity && (tabWidth == nil || tabWidth == width)
    }

    /// 业务作用：由实际视觉列取得完整组合字形端点，窗口裁剪不分离字母及附标。
    /// 参数说明:
    /// - cell: 相对逻辑行首的可见字形列。
    /// 返回：不越过目标列的相对 UTF-16 边界，Tab 内部返回该 Tab 的左端。
    public func character(atCell cell: Int) -> Int? {
        guard (0...cellCount).contains(cell) else {
            return nil
        }
        if cell == cellCount {
            return characterCount
        }
        return seek(from: checkpoint(atOrBefore: cell, using: \.cell)) { $0.cell <= cell }.character
    }

    /// 业务作用：窗口的 UTF-16 裁剪范围向前收束到实际组合字形边界。
    /// 参数说明:
    /// - character: 相对完整逻辑行首的原始 UTF-16 偏移。
    /// 返回：可安全裁剪的相对 UTF-16 端点，行外为空。
    public func boundary(atOrBefore character: Int) -> Int? {
        position(atOrBefore: character)?.character
    }

    /// 业务作用：选择可见原字节右端时保留最右处组合字形的全部附标。
    /// 参数说明:
    /// - character: 相对完整逻辑行首的原始 UTF-16 偏移。
    /// 返回：不早于请求的首个完整组合边界，行外为空。
    public func boundary(atOrAfter character: Int) -> Int? {
        position(atOrBefore: character).map { $0.character == character ? character : character + 1 }
    }

    /// 业务作用：完整行的横向前缀沿原生插入点度量，一个受支持组合只占一列。
    /// 参数说明:
    /// - character: 行内 UTF-16 端点，含基础字母与附标之间的原位置。
    /// 返回：视觉列，簇内位置沿原生插入语义采用右端。行外为空。
    public func cell(at character: Int) -> Int? {
        position(atOrBefore: character).map { character == $0.character ? $0.cell : $0.cell + 1 }
    }

    /// 业务作用：把显示使用的真实 UTF-16 端点换回完整正文中的原字节位置。
    /// 参数说明:
    /// - character: 完整逻辑行内的 UTF-16 端点。
    /// 返回：有效时为绝对原字节位置，超出行范围时为空。
    public func byte(at character: Int) -> Int? {
        text.byteOffset(utf16: character).map { range.lower + $0 }
    }

    /// 业务作用：缩进操作必须在完整组合字形之外取得逻辑列。
    /// 参数说明:
    /// - byte: 完整正文的原字节端点。
    /// 返回：字形边界对应的编辑列。簇内、标量中间及行外位置均为空。
    func cell(atByte byte: Int) -> Int? {
        guard (range.lower...range.upper).contains(byte),
            let character = text.utf16Offset(byte: byte - range.lower),
            let position = position(atOrBefore: character), position.character == character
        else {
            return nil
        }
        return position.cell
    }

    /// 业务作用：定位请求字符附近的稀疏检查点，最多解码一个有限区间。
    /// 参数说明:
    /// - character: 相对行首的原始 UTF-16 端点。
    /// 返回：不越过请求字符的完整组合边界，行外为空。
    private func position(atOrBefore character: Int) -> Position? {
        guard (0...characterCount).contains(character) else {
            return nil
        }
        return seek(from: checkpoint(atOrBefore: character, using: \.character)) { $0.character <= character }
    }

    /// 业务作用：按实际字形列或 UTF-16 端点查找同一个原字节检查点区间。
    /// 参数说明:
    /// - value: 已收束到完整原行的目标坐标。
    /// - coordinate: 本次采用的单调检查点坐标。
    /// 返回：目标位置之前最近的合法检查点编号。
    private func checkpoint(atOrBefore value: Int, using coordinate: KeyPath<Position, Int>) -> Int {
        var lower = 0
        var upper = checkpoints.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if checkpoints[middle][keyPath: coordinate] <= value {
                lower = middle
            }
            else {
                upper = middle
            }
        }
        return lower
    }

    /// 业务作用：在已确认且不截断组合字形的检查点区间内解码原字节。
    /// 参数说明:
    /// - checkpoint: 请求坐标前的已验证检查点编号。
    /// - fits: 给定下一完整边界是否仍处于请求坐标内。
    /// 返回：范围内最后一个不越过请求的完整字形位置。
    private func seek(from checkpoint: Int, fits: (Position) -> Bool) -> Position {
        var position = checkpoints[checkpoint]
        guard checkpoint + 1 < checkpoints.count else {
            return position
        }
        let base = position.byte
        let end = checkpoints[checkpoint + 1].byte
        let bytes = text.bytes(in: ByteRange(base, end))
        while position.byte < end {
            let local = position.byte - base
            let ascii = bytes[local] < 128
            let combining = ascii && local + 1 < bytes.count && bytes[local + 1] == 204
            let next = Position(
                byte: position.byte + (combining ? 3 : ascii ? 1 : 2),
                character: position.character + (combining ? 2 : 1),
                cell: position.cell
                    + ASCIITabColumns.advance(for: bytes[local], from: position.cell, tabWidth: tabWidth ?? 4)
            )
            guard fits(next) else {
                break
            }
            position = next
        }
        return position
    }

    /// 业务作用：扫描取消或超过时限时撤销整行资格，局部证据不能授予远端排版。
    /// 参数说明:
    /// - deadline: 同一原文准备动作的整体截止。
    /// 返回：有效时继续。取消或超过时限时抛出错误。
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("超长组合字形行测量超过五秒预算。")
        }
    }
}
