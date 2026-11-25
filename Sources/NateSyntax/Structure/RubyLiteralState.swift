import NateCore

struct RubyLiteralState: Equatable, Sendable {
    struct Delimiter: Equatable, Sendable {
        let closer: UInt8?
        let pairedOpener: UInt8?
        let interpolates: Bool
        let regularExpression: Bool
        let style: RubyHighlightStyle
        var nesting = 1
        var characterClass = false
    }

    private enum Region: Equatable, Sendable {
        case literal(Delimiter)
        case interpolation(depth: Int, position: RubyCodePosition)
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

    /// 业务作用：heredoc 的正文字面由完整物理行结束，单个正文字符没有结束权限。
    /// 参数说明:
    /// - style: 当前 heredoc 声明确定的原生正文样式。
    /// 返回：可继续跨行读取表达式的独立字面状态。
    mutating func beginHeredoc(style: RubyHighlightStyle) {
        begin(
            Delimiter(
                closer: nil,
                pairedOpener: nil,
                interpolates: true,
                regularExpression: false,
                style: style
            )
        )
    }

    /// 业务作用：恢复当前物理行的插值层级，主题分类器不借用外层代码状态。
    /// 参数说明: 无。
    /// 返回：尚未闭合的插值数量。
    var interpolationDepth: Int {
        regions.count { region in
            if case .interpolation = region {
                return true
            }
            return false
        }
    }

    /// 业务作用：物理换行使用当前最内层字面或普通表达式的原生类别。
    /// 参数说明: 无。
    /// 返回：当前行结束符的样式，字面已经结束时不提供样式。
    var liveStyle: RubyHighlightStyle? {
        switch regions.last {
        case .literal(let delimiter):
            return delimiter.style
        case .interpolation:
            return .whitespace
        case nil:
            return nil
        }
    }

    /// 业务作用：完整跳过当前字面及内层插值，同时为独立着色保留可证明的原始范围。
    /// 参数说明:
    /// - bytes: 当前固定物理行不含结束符的原字节。
    /// - index: 已消费的原字节位置。
    /// - highlights: 着色调用的相对范围记录，结构调用不分配该记录。
    /// - heredocs: 当前物理行已确认的 heredoc 声明，正文从下一物理行开始。
    /// - check: 整次读取的共同继续资格。
    /// 返回：推进到字面的真实终点或物理行尾，尚未结束的状态沿原界定符保留。
    mutating func advance(
        in bytes: [UInt8],
        from index: inout Int,
        highlights: inout RubyInterpolationHighlights?,
        heredocs: inout [RubyHeredoc],
        check: () throws -> Void
    ) throws {
        while index < bytes.count, let region = regions.popLast() {
            try check()
            let start = index
            let byte = bytes[index]
            let following = index + 1 < bytes.count ? bytes[index + 1] : 0
            switch region {
            case .literal(var delimiter):
                if byte == 92 {
                    index = min(bytes.count, index + 2)
                    regions.append(.literal(delimiter))
                    if regions.count > 1 {
                        try highlights?.paint(delimiter.style, in: ByteRange(start, index))
                    }
                    continue
                }
                if delimiter.interpolates, byte == 35 {
                    if following == 123 {
                        regions.append(.literal(delimiter))
                        try Self.requireRoom(regions.count)
                        regions.append(.interpolation(depth: 1, position: RubyCodePosition()))
                        index += 2
                        try highlights?.append(.enter(ByteRange(start, index)))
                        continue
                    }
                    if following == 64 || following == 36 {
                        index += 1
                        var position = RubyCodePosition()
                        let variable = try position.take(in: bytes, from: &index, check: check)
                        let style: RubyHighlightStyle =
                            following == 36
                            ? .global
                            : index > start + 2 && bytes[start + 2] == 64
                                ? .classVariable : .instance
                        try highlights?.paint(.operation, in: ByteRange(start, start + 1))
                        try highlights?.paint(style, in: variable.span)
                        regions.append(.literal(delimiter))
                        continue
                    }
                }
                let nested = !regions.isEmpty
                index += 1
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
                    // 正则的实际选项依赖原终止符，不能把相邻选项拆成普通词。
                    while index < bytes.count,
                        [105, 109, 120, 111, 117, 101, 115, 110].contains(bytes[index])
                    {
                        try check()
                        index += 1
                    }
                }
                if nested {
                    try highlights?.paint(delimiter.style, in: ByteRange(start, index))
                }
            case .interpolation(let depth, var position):
                if RubyIndentationLexer.blank(byte) {
                    index += 1
                    try highlights?.paint(.whitespace, in: ByteRange(start, index))
                    regions.append(.interpolation(depth: depth, position: position))
                    continue
                }
                if byte == 35 {
                    index = bytes.count
                    regions.append(.interpolation(depth: depth, position: position))
                    try highlights?.paint(.lineComment, in: ByteRange(start, index))
                    continue
                }
                if let token = try position.takeStandaloneLiteral(in: bytes, from: &index, check: check) {
                    regions.append(.interpolation(depth: depth, position: position))
                    try highlights?.append(.token(token))
                    continue
                }
                let acceptsLiteral = position.acceptsLiteral(in: bytes, at: index)
                if acceptsLiteral,
                    let (opening, after) = try RubyHeredoc.opening(in: bytes, at: index, check: check)
                {
                    // 声明行剩余表达式仍可闭合；正文从下一物理行按相同队列顺序读取，期间暂停外部字面。
                    try RubyIndentationLexer.appendHeredoc(opening, to: &heredocs)
                    position.consumeValue()
                    regions.append(.interpolation(depth: depth, position: position))
                    index = after
                    try highlights?.append(
                        .token(
                            .init(
                                kind: .operand,
                                span: ByteRange(start, index),
                                highlightStyle: .heredocDelimiter
                            )
                        )
                    )
                    continue
                }
                if let (opening, after) = Self.opener(in: bytes, at: index, pattern: acceptsLiteral) {
                    position.consumeValue()
                    regions.append(.interpolation(depth: depth, position: position))
                    try Self.requireRoom(regions.count)
                    regions.append(.literal(opening))
                    index = after
                    try highlights?.append(
                        .token(
                            .init(
                                kind: .operand,
                                span: ByteRange(start, index),
                                highlightStyle: opening.style
                            )
                        )
                    )
                    continue
                }
                if byte == 125, depth == 1 {
                    index += 1
                    try highlights?.append(.leave(ByteRange(start, index)))
                    continue
                }
                if byte == 123 {
                    try Self.requireRoom(depth)
                }
                let token = try position.take(in: bytes, from: &index, check: check)
                let adjustment = byte == 123 ? 1 : byte == 125 ? -1 : 0
                regions.append(.interpolation(depth: depth + adjustment, position: position))
                try highlights?.append(.token(token))
            }
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
                    regularExpression: byte == 47,
                    style: RubyHighlightStyle.literal(bytes[index..<(index + 1)])
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
                regularExpression: marker == 114,
                style: RubyHighlightStyle.literal(bytes[index...position])
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
