import Foundation
import NateCore

extension ObjCLexing {
    /// 业务作用：原始类别按 Unicode 标量首字节投影，词法边界不切开 UTF-8 字符。
    /// 参数说明:
    /// - text: 已确认的显示原文。
    /// - base: 当前请求的原字节起点。
    /// - origin: 完整物理类别的原字节起点。
    /// - classes: 固定完整物理范围的类别。
    /// - styles: 当前资源的完整样式。
    /// - budget: 与扫描共用的执行预算。
    /// 返回：最多 65536 个完整词元，超量或缺少样式时整体拒绝。
    static func tokens(
        _ text: String,
        base: Int,
        origin: Int,
        classes: [UInt8],
        styles: [String: LanguageTokenStyle],
        budget: inout ANSILexingBudget
    ) throws -> [SyntaxToken] {
        var output: [SyntaxToken] = []
        var offset = base
        var start = base
        var style: UInt8?
        for scalar in text.unicodeScalars {
            try budget.consume()
            let actual = classes[offset - origin]
            if let previous = style, actual != previous {
                try appendToken(start..<offset, style: previous, styles: styles, output: &output)
                start = offset
            }
            style = actual
            offset += scalar.utf8.count
        }
        if let style {
            try appendToken(start..<offset, style: style, styles: styles, output: &output)
        }
        return output
    }

    /// 业务作用：字符串、正则、UUID 与各类注释保持结构不透明，指令及限定词保留独立样式。
    /// 参数说明:
    /// - range: 已确认的完整标量范围。
    /// - style: ObjC 原生类别。
    /// - styles: 当前完整样式资源。
    /// - output: 尚未发布的有界词元。
    /// 返回：完整词元加入结果，缺少样式或数量超限时不降级为另一类别。
    private static func appendToken(
        _ range: Range<Int>,
        style: UInt8,
        styles: [String: LanguageTokenStyle],
        output: inout [SyntaxToken]
    ) throws {
        guard output.count < 65_536, let attributes = styles[String(style)] else {
            throw NateError.message("ObjC 高亮超过词元容量或缺少当前样式。")
        }
        let kind: SyntaxKind
        switch style {
        case 1, 2, 3, 15, 17, 18: kind = .comment
        case 6, 7, 8, 12, 13, 14: kind = .string
        case 4: kind = .number
        case 9: kind = .tag
        case 10: kind = .punctuation
        case 5, 16, 20, 21: kind = .keyword
        default: kind = .text
        }
        output.append(
            SyntaxToken(
                range: ByteRange(range.lowerBound, range.upperBound),
                kind: kind,
                foreground: attributes.foreground,
                background: attributes.background,
                fontStyle: attributes.fontStyle,
                lexicalStyle: "objc:" + String(style)
            )
        )
    }
}
