import AppKit
import NateCore
import NateSyntax

@MainActor
final class UDLFontMetrics {
    private var base: NSFont?
    private var generation: UUID?
    private var measured: CGFloat = 20
    private var adjustment: CGFloat = 0
    private var themeIdentity: String?
    private var themeLanguage: String?
    var zoomBaseFont: NSFont?
    var zoomAdjustment: CGFloat = 0
    private let names: Set<String> = Set(
        [
            "DEFAULT", "COMMENTS", "LINE COMMENTS", "NUMBERS", "OPERATORS", "FOLDER IN CODE1",
            "FOLDER IN CODE2", "FOLDER IN COMMENT",
        ]
            + (1...8).map {
                "KEYWORDS\($0)"
            }
            + (1...8).map {
                "DELIMITERS\($0)"
            }
    )

    /// 业务作用：字号不同的 UDL 样式共用足够的逻辑行高度，非换行视图不能让较大字形覆盖相邻正文。
    /// 参数说明:
    /// - font: 当前视图实际基础字体。
    /// - definition: 当前完整用户语言，规则代次包含运行时样式变化。
    /// - theme: 当前已经完成编码与身份验证的主题。
    /// - language: 当前语言身份，用于限定精确字体覆盖。
    /// 返回：基础及有效样式的最大原生高度；相同字体、缩放差值与代次直接复用，未知样式不改变排版。
    func height(
        font: NSFont,
        definition: UDLDefinition?,
        theme: EditorThemeSnapshot? = nil,
        language: String? = nil
    ) -> CGFloat {
        guard
            base != font || generation != definition?.generation || adjustment != zoomAdjustment
                || themeIdentity != theme?.identity || themeLanguage != language
        else {
            return measured
        }
        base = font
        generation = definition?.generation
        adjustment = zoomAdjustment
        themeIdentity = theme?.identity
        themeLanguage = language
        measured = ceil(font.ascender - font.descender + font.leading + 5)
        for (name, style) in definition?.styles ?? [:] where names.contains(name) {
            let actual = SyntaxPresentation.resolvedFont(
                name: style.fontName,
                size: style.fontSize,
                style: style.fontStyle,
                base: font,
                adjustment: zoomAdjustment
            )
            measured = max(measured, ceil(actual.ascender - actual.descender + actual.leading + 5))
        }
        if let theme {
            let styles =
                Array(theme.definition.kindStyles.values)
                + Array((theme.definition.languageStyles[language ?? ""] ?? [:]).values)
            for style in styles {
                let actual = SyntaxPresentation.resolvedFont(
                    name: style.fontName,
                    size: style.fontSize,
                    style: style.fontStyle ?? 0,
                    base: font,
                    adjustment: zoomAdjustment
                )
                measured = max(measured, ceil(actual.ascender - actual.descender + actual.leading + 5))
            }
        }
        return measured
    }
}
