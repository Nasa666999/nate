import AppKit
import NateCore

@MainActor
public struct PrintedSource {
    let text: PieceTree
    let plan: PrintSourcePlan
    let styled: NSAttributedString
    let settings: PrintSettings
    let values: [String: String]
    let showControls: Bool
    let baseFont: NSFont
    let background: NSColor

    /// 业务作用：打印与预览只持有固定正文及独立样式，不借用活动编辑器的文字存储或布局管理器。
    /// 参数说明:
    /// - plan: 明确全文或选区的完整分页源范围。
    /// - styled: 仅包含源范围的属性文字，UTF-16 长度必须精确匹配原文；仅采纳纯文本呈现属性，不渲染附件。
    /// - settings: 已验证的打印配置。
    /// - values: 作业开始时固定的文件与日期时间变量。
    /// - showControls: 是否在打印时呈现 FF 的可见控制符。
    /// - baseFont: 原正文实际字体，页眉页脚空字体名时沿用其字体家族。
    /// - background: 原编辑器实际背景色，不随后来的外观切换变化。
    /// 返回：与源文字一致的固定输出来源；不一致、超量、指定字体不可用或缺失模板变量时拒绝全部作业。
    public init(
        plan: PrintSourcePlan,
        styled: NSAttributedString,
        settings: PrintSettings,
        values: [String: String],
        showControls: Bool,
        baseFont: NSFont,
        background: NSColor
    ) throws {
        // 范围和强制分页只能解释规划时的同一正文树，不能借相同长度套用另一文档。
        let text = plan.text
        guard let range = text.nsRange(plan.range), styled.length == range.length,
            styled.string.utf8.count <= 64 * 1024 * 1024,
            styled.string.utf8.elementsEqual(text.text(in: plan.range).utf8)
        else {
            throw NateError.message("独立打印样式与完整源范围不一致，或源范围超过 64 MiB。")
        }
        for decoration in [settings.header, settings.footer] {
            guard
                decoration.fontName.isEmpty
                    || NSFont(
                        name: decoration.fontName,
                        size: decoration.fontSize
                    ) != nil
            else {
                throw NateError.message("打印页眉页脚的指定字体不可用：\(decoration.fontName)。")
            }
            for value in [decoration.left, decoration.middle, decoration.right] {
                _ = try PrintTemplate(value).render(values: values, page: 100_000, totalPages: 100_000)
            }
        }
        self.text = text
        self.plan = plan
        let frozen = NSMutableAttributedString(string: styled.string)
        let whole = NSRange(
            location: 0,
            length: styled.length
        )
        styled.enumerateAttributes(in: whole) { attributes, range, _ in
            var selected: [NSAttributedString.Key: Any] = [:]
            for key in [
                NSAttributedString.Key.font, .foregroundColor, .backgroundColor,
                .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor,
                .baselineOffset, .kern, .ligature,
            ] {
                if let color = attributes[key] as? NSColor {
                    selected[key] = color.usingColorSpace(.deviceRGB) ?? .black
                }
                else if let font = attributes[key] as? NSFont {
                    selected[key] = font
                }
                else if let number = attributes[key] as? NSNumber {
                    selected[key] = NSNumber(value: number.doubleValue)
                }
            }
            // 段落样式可变，必须独立复制；附件和其它对象不能借属性字典取得资源加载或后续变更权。
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                selected[.paragraphStyle] = paragraph.copy()
            }
            frozen.setAttributes(selected, range: range)
        }
        self.styled = NSAttributedString(attributedString: frozen)
        self.settings = settings
        self.values = values
        self.showControls = showControls
        self.baseFont = baseFont
        self.background = background.usingColorSpace(.deviceRGB) ?? .white
    }
}
