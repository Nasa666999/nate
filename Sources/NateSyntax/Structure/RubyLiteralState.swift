import NateCore

struct RubyLiteralState: Equatable, Sendable {
    struct Delimiter: Equatable, Sendable {
        let closer: UInt8
        let pairedOpener: UInt8?
        let interpolates: Bool
        let regularExpression: Bool
        var nesting = 1
        var characterClass = false
    }

    private enum Region: Equatable, Sendable {
        case literal(Delimiter)
        case interpolation(Int)
    }

    private var regions: [Region] = []

    /// 业务作用：跨行字面及内部插值持续屏蔽结构词，光标换行不会把字面中的 end 当作闭合。
    /// 参数说明: 无。
    /// 返回：还有待结束的字面或插值上下文时为真。
    var isOpen: Bool {
        !regions.isEmpty
    }

    /// 业务作用：进入已经由原代码位置确认的字面，后续行保留同一实际界定符。
    /// 参数说明:
    /// - delimiter: Ruby 当前识别到的引号、百分号形式或正则的完整边界。
    /// 返回：字面在后续读取中暂时隔离内部所有结构词。
    mutating func begin(_ delimiter: Delimiter) {
        regions.append(.literal(delimiter))
    }

    /// 业务作用：完整跳过当前字面、配对分隔符及其内层插值，读取完毕前不给字面标点代码语义。
    /// 参数说明:
    /// - bytes: 当前固定物理行不含结束符的原字节。
    /// - index: 已消费的原字节位置。
    /// - check: 当前整次换行的共同继续资格。
    /// 返回：推进到字面的真实终点或物理行尾，尚未结束的状态沿原界定符保留。
    mutating func advance(in bytes: [UInt8], from index: inout Int, check: () throws -> Void) throws {
        while isOpen && index < bytes.count {
            try check()
            let byte = bytes[index]
            let following = index + 1 < bytes.count ? bytes[index + 1] : 0
            guard let region = regions.popLast() else {
                break
            }
            if byte == 92 {
                index = min(bytes.count, index + 2)
                regions.append(region)
                continue
            }
            switch region {
            case .literal(var delimiter):
                if delimiter.interpolates, byte == 35, following == 123 {
                    regions.append(.literal(delimiter))
                    try Self.requireRoom(regions.count)
                    regions.append(.interpolation(1))
                    index += 2
                    continue
                }
                if delimiter.regularExpression, delimiter.closer != 93 {
                    if byte == 91 {
                        delimiter.characterClass = true
                    }
                    else if byte == 93 {
                        delimiter.characterClass = false
                    }
                }
                if !delimiter.characterClass {
                    if byte == delimiter.closer {
                        delimiter.nesting -= 1
                    }
                    else if byte == delimiter.pairedOpener {
                        try Self.requireRoom(delimiter.nesting)
                        delimiter.nesting += 1
                    }
                }
                if delimiter.nesting > 0 {
                    regions.append(.literal(delimiter))
                }
                else if delimiter.regularExpression {
                    index += 1
                    // 正则的实际选项依赖原终止符，不能把相邻选项拆成普通词。
                    while index < bytes.count,
                        [105, 109, 120, 111, 117, 101, 115, 110].contains(bytes[index])
                    {
                        try check()
                        index += 1
                    }
                    continue
                }
            case .interpolation(let depth):
                if byte == 35 {
                    regions.append(.interpolation(depth))
                    index = bytes.count
                    continue
                }
                let before = index == 0 ? 0 : bytes[index - 1]
                let startsExpression = [0, 9, 32, 33, 40, 44, 58, 59, 61, 91, 123].contains(before)
                if let (opening, after) = Self.opener(in: bytes, at: index, pattern: startsExpression) {
                    regions.append(.interpolation(depth))
                    try Self.requireRoom(regions.count)
                    regions.append(.literal(opening))
                    index = after
                    continue
                }
                if byte == 123 {
                    try Self.requireRoom(depth)
                    regions.append(.interpolation(depth + 1))
                }
                else if byte == 125 {
                    if depth > 1 {
                        regions.append(.interpolation(depth - 1))
                    }
                }
                else {
                    regions.append(.interpolation(depth))
                }
            }
            index += 1
        }
    }

    /// 业务作用：解释 Ruby 的实际字面端点，只有表达式位置才借用正则或百分号规则。
    /// 参数说明:
    /// - bytes: 同一物理行的完整原字节。
    /// - index: 当前尚未消费的字节位置。
    /// - pattern: 当前代码位置允许正则或百分号字面时为真。
    /// 返回：已确认界定符及正文首字节，其它符号保持原代码身份。
    static func opener(in bytes: [UInt8], at index: Int, pattern: Bool) -> (Delimiter, Int)? {
        let byte = bytes[index]
        if byte == 34 || byte == 39 || byte == 96 || byte == 47 && pattern {
            return (
                Delimiter(
                    closer: byte,
                    pairedOpener: nil,
                    interpolates: byte != 39,
                    regularExpression: byte == 47
                ),
                index + 1
            )
        }
        guard byte == 37, pattern, index + 1 < bytes.count else {
            return nil
        }
        let marker = bytes[index + 1]
        let typed = [81, 87, 73, 105, 113, 114, 115, 119, 120].contains(marker)
        let position = index + (typed ? 2 : 1)
        guard position < bytes.count else {
            return nil
        }
        let opening = bytes[position]
        guard (33...126).contains(opening), !(48...57).contains(opening),
            !(65...90).contains(opening), !(97...122).contains(opening)
        else {
            return nil
        }
        let closer: UInt8? = [40: 41, 60: 62, 91: 93, 123: 125][opening]
        let interpolates = !typed || [81, 87, 73, 114, 120].contains(marker)
        return (
            Delimiter(
                closer: closer ?? opening,
                pairedOpener: closer == nil ? nil : opening,
                interpolates: interpolates,
                regularExpression: marker == 114
            ),
            position + 1
        )
    }

    /// 业务作用：限制嵌套字面与插值的共同空间，超量输入保留本次所有原正文和选区。
    /// 参数说明:
    /// - depth: 当前等待闭合的区间或同类分隔符深度。
    /// 返回：尚能接收下一层时通过，否则终止整批换行准备。
    private static func requireRoom(_ depth: Int) throws {
        guard depth < 256 else {
            throw NateError.message("Ruby 字面结构超过 256 层。")
        }
    }
}
