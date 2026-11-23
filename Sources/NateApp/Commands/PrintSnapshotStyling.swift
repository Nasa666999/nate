import AppKit
import NateCore
import NateSyntax
import NateUI

extension ApplicationController {
    /// 业务作用：打印与富文本导出使用同一固定语言来源，选区之前只传播状态而不进入输出文字。
    /// 参数说明:
    /// - snapshot: 原正文与修订固定的唯一来源。
    /// - range: 明确全文或选择范围。
    /// - language: 作业开始时实际语言身份。
    /// - udl: 来源视图实际采用的用户语言，为空时使用内置词法。
    /// - font: 来源视图基础字体。
    /// - fontZoomAdjustment: 来源视图已确认的资源字号缩放差值。
    /// - theme: 来源视图固定的完整主题；黑白方案不采用主题颜色。
    /// - appearance: 来源视图实际外观。
    /// - rtl: 来源段落基础方向。
    /// - color: 黑白方案不请求语法高亮，其余沿用来源内置或 UDL 样式。
    /// 返回：完整源范围、原坐标与固定样式；词法失败、超量或超时不返回部分呈现。
    func styledPrintSnapshot(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        language: String,
        udl: UDLDefinition? = nil,
        font: NSFont,
        fontZoomAdjustment: CGFloat = 0,
        theme: EditorThemeSnapshot? = nil,
        appearance: NSAppearance,
        rtl: Bool,
        color: PrintColorMode
    ) throws -> NSAttributedString {
        guard range.count <= 64 * 1024 * 1024, let projection = snapshot.text.nsRange(range) else {
            throw NateError.message("独立打印样式需要至多 64 MiB 的合法源范围。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var baseAttributes = SyntaxPresentation.attributes(
            token: SyntaxToken(range: ByteRange(0, 0), kind: .text, lexicalStyle: "default:0"),
            font: font,
            appearance: appearance,
            fontZoomAdjustment: fontZoomAdjustment,
            theme: color == .blackOnWhite ? nil : theme?.definition,
            language: language
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.tabStops = []
        paragraph.defaultTabInterval =
            (" " as NSString).size(withAttributes: [.font: baseAttributes[.font] ?? font]).width
            * CGFloat(currentTabSettings().settings(for: language).width)
        baseAttributes[.paragraphStyle] = paragraph
        let value = NSMutableAttributedString(
            string: snapshot.text.text(in: range),
            attributes: baseAttributes
        )
        guard color != .blackOnWhite, !range.isEmpty else {
            return value
        }
        guard let definition = udl?.languageDefinition() ?? registry?.language(language) else {
            // 用户语言缺失时不能把未解释的正文当作已完成样式输出，必须让用户重新选择有效定义。
            guard !language.hasPrefix("udl:") else {
                throw NateError.message("用户语言定义不可用，未生成缺少样式的输出。")
            }
            return value
        }
        guard udl != nil || !["normal", "nfo"].contains(definition.id) else {
            return value
        }
        var state = SyntaxState()
        var userState = UDLState()
        let scanner = SyntaxScanner(language: definition, snapshot: snapshot)
        let last = snapshot.text.lineNumber(at: max(range.lower, range.upper - 1))
        guard last < 1_048_576 else {
            throw NateError.message("输出词法传播超过 1048576 行，未采用部分样式。")
        }
        var consumed = 0
        var fragments = 0
        for line in 0...last {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("输出完整词法样式超过五秒预算，未采用部分高亮。")
            }
            let row = snapshot.text.lineRange(line)
            // 选区前缀与实际输出共用容量，不能为很小的末尾选区先复制无限的远处上下文。
            guard row.count <= 1_048_576, consumed <= 64 * 1024 * 1024 - row.count else {
                throw NateError.message("输出词法传播超过单行 1 MiB 或合计 64 MiB，未猜测后续样式。")
            }
            consumed += row.count
            let text = snapshot.text.text(in: row)
            let tokens =
                udl.map {
                    UDLLexer.highlight(
                        text,
                        base: row.lower,
                        definition: $0,
                        state: &userState,
                        source: snapshot,
                        deadline: deadline
                    )
                } ?? scanner.highlight(text, base: row.lower, state: &state)
            if let diagnostic = userState.diagnostic ?? state.diagnostic {
                throw NateError.message(diagnostic)
            }
            guard tokens.count <= 1_048_576 - fragments else {
                throw NateError.message("输出词法片段合计超过 1048576 个，未采用部分样式。")
            }
            fragments += tokens.count
            for token in tokens where token.range.lower < range.upper && token.range.upper > range.lower {
                let clipped = ByteRange(
                    max(range.lower, token.range.lower),
                    min(range.upper, token.range.upper)
                )
                guard let native = snapshot.text.nsRange(clipped), native.location >= projection.location
                else {
                    throw NateError.invalidRange
                }
                value.addAttributes(
                    SyntaxPresentation.attributes(
                        token: token,
                        font: font,
                        appearance: appearance,
                        fontZoomAdjustment: fontZoomAdjustment,
                        theme: theme?.definition,
                        language: language
                    ),
                    range: NSRange(
                        location: native.location - projection.location,
                        length: native.length
                    )
                )
            }
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("输出完整词法样式超过五秒预算。")
        }
        return NSAttributedString(attributedString: value)
    }
}
