import AppKit
import NateCore
import NateSyntax
import NateUI

extension ApplicationController {
    /// 业务作用：独立打印只构建实际源范围的样式，选区之前的词法传播不进入输出文字。
    /// 参数说明:
    /// - snapshot: 原正文与修订固定的唯一来源。
    /// - range: 明确全文或选择范围。
    /// - language: 作业开始时实际语言身份。
    /// - font: 来源视图基础字体。
    /// - appearance: 来源视图实际外观。
    /// - rtl: 来源段落基础方向。
    /// - color: 黑白方案不请求语法高亮，其余沿用正文真实样式。
    /// 返回：完整源范围、原坐标与固定样式；词法失败、超量或超时不返回部分呈现。
    func styledPrintSnapshot(
        snapshot: DocumentSnapshot,
        range: ByteRange,
        language: String,
        font: NSFont,
        appearance: NSAppearance,
        rtl: Bool,
        color: PrintColorMode
    ) throws -> NSAttributedString {
        guard range.count <= 64 * 1024 * 1024, let projection = snapshot.text.nsRange(range) else {
            throw NateError.message("独立打印样式需要至多 64 MiB 的合法源范围。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        let value = NSMutableAttributedString(
            string: snapshot.text.text(in: range),
            attributes: [
                .font: font,
                .foregroundColor: SyntaxPresentation.resolved(.textColor, appearance: appearance),
                .paragraphStyle: paragraph,
            ]
        )
        guard color != .blackOnWhite, let definition = registry?.language(language),
            !["normal", "nfo"].contains(definition.id), !range.isEmpty
        else {
            return value
        }
        var state = SyntaxState()
        let scanner = SyntaxScanner(language: definition, snapshot: snapshot)
        let last = snapshot.text.lineNumber(at: max(range.lower, range.upper - 1))
        for line in 0...last {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw NateError.message("打印完整词法样式超过五秒预算，未采用部分高亮。")
            }
            let row = snapshot.text.lineRange(line)
            guard row.count <= 64 * 1024 * 1024 else {
                throw NateError.message("打印词法传播涉及超过 64 MiB 的逻辑行，未猜测其后样式。")
            }
            let tokens = scanner.highlight(snapshot.text.text(in: row), base: row.lower, state: &state)
            if let diagnostic = state.diagnostic {
                throw NateError.message(diagnostic)
            }
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
                    SyntaxPresentation.attributes(token: token, font: font, appearance: appearance),
                    range: NSRange(
                        location: native.location - projection.location,
                        length: native.length
                    )
                )
            }
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("打印完整词法样式超过五秒预算。")
        }
        return value
    }
}
