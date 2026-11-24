import Foundation

public struct PlainHanLine: Sendable {
    public let range: ByteRange
    public let characterCount: Int
    public let containsOnlyUnifiedIdeographs: Bool
    private let sourceIdentity: UUID
    private let text: PieceTree
    private let checkpoints: [Int]
    private static let interval = 1024
    public static let fullwidthPunctuation = Array("　、。〈〉《》「」『』【】〔〕！（），：；？［］｛｝".utf16)
    private static let punctuationScalars = Set(fullwidthPunctuation)

    private enum UnsupportedText: Error {
        case scalar
    }

    /// 业务作用：后台确认完整长行只包含独立可打印 ASCII、基本统一汉字及明确全角标点，建立有界原字节索引。
    /// 参数说明:
    /// - source: 当前文档的不可变正文。
    /// - range: 逻辑行正文的 UTF-8 范围，排除物理行尾。
    /// - deadline: 此行测量的共同截止。
    /// 返回：独立标量与有界最远查找证据；方向控制、组合字符、其它字符或超限不能取得此布局资格。
    public init?(
        text source: PieceTree,
        range: ByteRange,
        deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))
    ) throws {
        guard range.lower >= 0, range.lower < range.upper, range.upper <= source.byteCount,
            source.isBoundary(range.lower), source.isBoundary(range.upper),
            range.count <= ASCIITabColumns.maximumBytes
        else {
            return nil
        }
        let slice = try source.slicing(range)
        guard slice.byteCount > slice.utf16Count else {
            return nil
        }
        if source.containsOnlyUnifiedIdeographs(in: range) {
            // 固定三字节宽度已由不可变节点确认，可跳过逐块构建检查点，仍保留同一正文和时限门禁。
            try Self.requireTime(until: deadline)
            self.range = range
            sourceIdentity = source.root.identity
            text = slice
            characterCount = range.count / 3
            containsOnlyUnifiedIdeographs = true
            checkpoints = []
            return
        }
        var bytes = 0
        var characters = 0
        var next = Self.interval
        var checkpoints = [0]
        checkpoints.reserveCapacity(1 + slice.utf16Count / Self.interval)
        do {
            try slice.forEachChunk(maximumBytes: 65_536) { chunk in
                try Self.requireTime(until: deadline)
                if chunk.tree.isPrintableASCII(in: ByteRange(0, chunk.byteCount)) {
                    let end = characters + chunk.byteCount
                    while next <= end {
                        checkpoints.append(bytes + next - characters)
                        next += Self.interval
                    }
                    bytes += chunk.byteCount
                    characters = end
                    return
                }
                let data = chunk.bytes()
                var index = 0
                while index < data.count {
                    let leading = data[index]
                    let size: Int
                    if (32...126).contains(leading) {
                        size = 1
                    }
                    // UTF-8 已由正文树验证。E4 B8 80 至 E9 BF BF 是 BMP 的基本统一汉字区间。
                    else if (229...233).contains(leading) || (leading == 228 && data[index + 1] >= 184) {
                        size = 3
                    }
                    else if leading == 227 || leading == 239 {
                        let scalar =
                            (UInt16(leading & 15) << 12)
                            | (UInt16(data[index + 1] & 63) << 6) | UInt16(data[index + 2] & 63)
                        guard Self.punctuationScalars.contains(scalar) else {
                            throw UnsupportedText.scalar
                        }
                        size = 3
                    }
                    else {
                        throw UnsupportedText.scalar
                    }
                    index += size
                    bytes += size
                    characters += 1
                    if characters == next {
                        checkpoints.append(bytes)
                        next += Self.interval
                    }
                }
            }
        }
        catch UnsupportedText.scalar {
            return nil
        }
        try Self.requireTime(until: deadline)
        self.range = range
        self.sourceIdentity = source.root.identity
        self.text = slice
        self.characterCount = characters
        containsOnlyUnifiedIdeographs = false
        self.checkpoints = checkpoints
    }

    /// 业务作用：原字节索引和原生属性使用同一全角字符集合，窗口不能采用索引未覆盖的字体度量。
    /// 参数说明:
    /// - scalar: 已验证的单个 UTF-16 单元。
    /// 返回：属于基本统一汉字或明确支持的全角标点时为真。
    public static func usesHanFont(_ scalar: UInt16) -> Bool {
        (0x4E00...0x9FFF).contains(scalar) || punctuationScalars.contains(scalar)
    }

    /// 业务作用：排版只能使用建立索引时的不可变正文根，相同长度的新修订也需重新测量。
    /// 参数说明:
    /// - source: 当前排版固定的正文树。
    /// 返回：当前树是产生本索引的同一根时为真。
    public func matches(_ source: PieceTree) -> Bool {
        sourceIdentity == source.root.identity
    }

    /// 业务作用：有界原生窗口由精确字符端点取正文，两个不等宽字符集仍共用原字节来源。
    /// 参数说明:
    /// - character: 行首起算的 UTF-16 偏移，经过验证的区间每标量占一个单元。
    /// 返回：完整正文的原 UTF-8 端点，行外偏移为空。
    public func byte(at character: Int) -> Int? {
        if containsOnlyUnifiedIdeographs {
            return (0...characterCount).contains(character) ? range.lower + character * 3 : nil
        }
        return text.byteOffset(utf16: character).map { range.lower + $0 }
    }

    /// 业务作用：普通光标的逻辑列与实际汉字长行共享原字节证据，每个已验证标量都是独立字素。
    /// 参数说明:
    /// - offset: 完整正文内的真实原字节端点。
    /// 返回：相对逻辑行首的字符数；行外或切开标量的偏移为空。
    public func character(atByte offset: Int) -> Int? {
        guard (range.lower...range.upper).contains(offset) else {
            return nil
        }
        let relative = offset - range.lower
        if containsOnlyUnifiedIdeographs {
            return relative.isMultiple(of: 3) ? relative / 3 : nil
        }
        return text.utf16Offset(byte: relative)
    }

    /// 业务作用：原生行宽和窗口偏移使用实际已测字体距离，按原字节数量精确区分 ASCII 与汉字。
    /// 参数说明:
    /// - character: 行首起算的真实 UTF-16 端点。
    /// - ascii: 已测的单个 ASCII 字形宽度。
    /// - han: 已测的单个基本汉字和全角标点的字形宽度。
    /// 返回：合法端点距完整行首的横坐标；无效端点或宽度为空。
    public func distance(through character: Int, ascii: Double, han: Double) -> Double? {
        guard ascii.isFinite, han.isFinite,
            (0...4096).contains(ascii), (0...4096).contains(han), ascii > 0, han > 0,
            let offset = byte(at: character)
        else {
            return nil
        }
        return Self.distance(bytes: offset - range.lower, characters: character, ascii: ascii, han: han)
    }

    /// 业务作用：通过浏览位置选取附近原生片段，只访问一个已验证分块的原字节。
    /// 参数说明:
    /// - x: 相对逻辑行首的实际横坐标。
    /// - ascii: 此视图已测的 ASCII 单字符间距。
    /// - han: 此视图已测的全角字符的实测间距。
    /// 返回：不越过给定位置的实际 UTF-16 端点；未确认有效位置时为空。
    public func character(atOrBefore x: Double, ascii: Double, han: Double) -> Int? {
        guard x.isFinite, x >= 0,
            let fullWidth = distance(through: characterCount, ascii: ascii, han: han), x <= fullWidth
        else {
            return nil
        }
        if containsOnlyUnifiedIdeographs {
            let estimate = min(characterCount, Int((x / han).rounded(.down)))
            // 远端的浮点除法可能把原生端点舍入一列；用同一字形乘积复验相邻插入点。
            if estimate < characterCount, Double(estimate + 1) * han <= x {
                return estimate + 1
            }
            if estimate > 0, Double(estimate) * han > x {
                return estimate - 1
            }
            return estimate
        }
        var lower = 0
        var upper = checkpoints.count
        while lower + 1 < upper {
            let middle = lower + (upper - lower) / 2
            let distance = Self.distance(
                bytes: checkpoints[middle],
                characters: middle * Self.interval,
                ascii: ascii,
                han: han
            )
            if distance <= x {
                lower = middle
            }
            else {
                upper = middle
            }
        }
        var consumed = checkpoints[lower]
        var character = lower * Self.interval
        let end = upper < checkpoints.count ? checkpoints[upper] : range.count
        let bytes = text.bytes(in: ByteRange(consumed, end))
        var offset = 0
        while offset < bytes.count {
            let size = bytes[offset] < 128 ? 1 : 3
            let distance = Self.distance(
                bytes: consumed + size,
                characters: character + 1,
                ascii: ascii,
                han: han
            )
            guard distance <= x else {
                break
            }
            consumed += size
            offset += size
            character += 1
        }
        return character
    }

    /// 业务作用：同一已验证 UTF-16 前缀通过原字节差得到全角字符数，避免连续浮点累加造成远端误差。
    /// 参数说明:
    /// - bytes: 有效前缀的相对 UTF-8 字节数。
    /// - characters: 有效前缀的实际标量数。
    /// - ascii: 单个普通 ASCII 的实测间距。
    /// - han: 单个全角字符的实测间距。
    /// 返回：完整行首到该前缀末端的横向距离。
    private static func distance(bytes: Int, characters: Int, ascii: Double, han: Double) -> Double {
        let fullwidth = (bytes - characters) / 2
        return Double(characters - fullwidth) * ascii + Double(fullwidth) * han
    }

    /// 业务作用：当前索引只能在完整校验后交付，取消或测量超时不返回部分坐标。
    /// 参数说明:
    /// - deadline: 启动本行测量时冻结的截止。
    /// 返回：在共享预算内继续；取消或超时均抛出对应原因。
    private static func requireTime(until deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("超长汉字行测量超过五秒预算。")
        }
    }
}
