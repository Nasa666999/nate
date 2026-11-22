import Foundation
import NateCore

extension YAMLLexing {
    /// 业务作用：同一物理行中的引号范围保持结构不透明，颜色身份继续沿原 YAML 类别，不改变词法对照。
    /// 参数说明:
    /// - start: 当前真实物理行起点。
    /// - end: 包含结束符的末边界。
    /// 返回：引号、成对单引号及双引号转义的实际字节标记为字面范围，不创建正文编辑。
    mutating func quoteScope(_ start: Int, _ end: Int) throws {
        var quote: UInt8?
        var cursor = start
        while cursor < end {
            try budget.consume()
            let current = byte(cursor)
            if classes[cursor] == 1 || classes[cursor] == 7 {
                cursor += 1
                continue
            }
            if let active = quote {
                quoted[cursor] = true
                if active == 34, current == 92, cursor + 1 < end {
                    quoted[cursor + 1] = true
                    cursor += 2
                    continue
                }
                if current == active {
                    if active == 39, cursor + 1 < end, byte(cursor + 1) == 39 {
                        quoted[cursor + 1] = true
                        cursor += 2
                        continue
                    }
                    quote = nil
                }
            }
            else if current == 39 || current == 34 {
                quote = current
                quoted[cursor] = true
            }
            cursor += 1
        }
    }

    /// 业务作用：原生类别与引号作用域在完整 Unicode 标量上合并，UTF-8 中间字节不形成独立选区。
    /// 参数说明:
    /// - text: 已确认的当前显示范围。
    /// - base: 当前请求原字节起点。
    /// - origin: 完整类别缓冲的原字节起点。
    /// - state: 同源的完整物理行类别及字面范围。
    /// - rules: 当前固定样式。
    /// - budget: 与扫描共用的执行预算。
    /// 返回：最多 65536 个完整词元；任何容量或样式缺席都拒绝整份结果。
    static func tokens(
        _ text: String,
        base: Int,
        origin: Int,
        state: YAMLLexicalState,
        rules: YAMLRules,
        budget: inout ANSILexingBudget
    ) throws -> [SyntaxToken] {
        var output: [SyntaxToken] = []
        var start = base
        var offset = base
        var style: UInt8?
        var quoted = false
        for scalar in text.unicodeScalars {
            try budget.consume()
            let actual = state.cachedClasses[offset - origin]
            let literal = state.cachedQuoted[offset - origin]
            if let previous = style, actual != previous || quoted != literal {
                try appendToken(
                    start..<offset,
                    style: previous,
                    quoted: quoted,
                    rules: rules,
                    output: &output
                )
                start = offset
            }
            style = actual
            quoted = literal
            offset += scalar.utf8.count
        }
        if let style {
            try appendToken(start..<offset, style: style, quoted: quoted, rules: rules, output: &output)
        }
        return output
    }

    /// 业务作用：实际样式与结构作用域分别保留，冒号不会继承键名的粗体或关键字类别。
    /// 参数说明:
    /// - range: 已确认的完整原标量范围。
    /// - style: 原生 YAML 样式编号。
    /// - quoted: 该范围是否属于当前行的引号内容。
    /// - rules: 当前固定完整样式。
    /// - output: 尚未发布的全部词元。
    /// 返回：完整词元加入有界结果，缺少配置时不降级为其它类别。
    private static func appendToken(
        _ range: Range<Int>,
        style: UInt8,
        quoted: Bool,
        rules: YAMLRules,
        output: inout [SyntaxToken]
    ) throws {
        guard output.count < 65_536, let attributes = rules.styles[String(style)] else {
            throw NateError.message("YAML 高亮超过词元容量或缺少当前样式。")
        }
        let kind: SyntaxKind
        switch style {
        case 1: kind = .comment
        case 7: kind = .string
        default:
            if quoted {
                kind = .string
            }
            else {
                switch style {
                case 2, 5: kind = .tag
                case 3: kind = .keyword
                case 4: kind = .number
                case 6: kind = .heading
                case 9: kind = .punctuation
                default: kind = .text
                }
            }
        }
        output.append(
            SyntaxToken(
                range: ByteRange(range.lowerBound, range.upperBound),
                kind: kind,
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: "yaml:" + String(style)
            )
        )
    }
}
