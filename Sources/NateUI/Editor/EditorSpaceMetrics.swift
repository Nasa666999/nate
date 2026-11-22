import AppKit

extension EditorView {
    /// 业务作用：临时几何视图沿来源的真实换行容器宽度，不能因没有滚动容器而使用另一种软换行。
    /// 参数说明: 无。
    /// 返回：来源已确认的宽度或当前真实视口宽度；不换行时采用固定有界容器。
    var nativeBodyLayoutWidth: CGFloat {
        guard wrapLines else {
            return 1_000_000
        }
        if let width = geometryLayoutWidth, width.isFinite, (80...1_000_000).contains(width) {
            return width
        }
        return max(80, (enclosingScrollView?.contentSize.width ?? 900) - gutterWidth - 16)
    }

    /// 业务作用：没有正文或结束符的文件末行仍采用当前用户语言默认字体，不能退回无关的基础字号。
    /// 参数说明: 无。
    /// 返回：与默认语法样式及当前视图缩放一致的原生字体。
    var defaultVirtualSpaceFont: NSFont {
        let style = userLanguage?.styles["DEFAULT"]
        return SyntaxPresentation.resolvedFont(
            name: style?.fontName,
            size: style?.fontSize,
            style: style?.fontStyle ?? 0,
            base: font,
            adjustment: fontZoomAdjustment
        )
    }

    /// 业务作用：各真实行独立解释虚拟列，字体不同的多光标不能共用主行的空格宽度。
    /// 参数说明:
    /// - offset: 本行中的合法原字节位置。
    /// 返回：所属真实行的行末样式空格宽度；只读取原生布局，不改变选择或正文。
    func rectangleColumnWidth(at offset: Int) -> Double {
        layoutLine(document.text.lineNumber(at: offset)).virtualColumnWidth
    }
}
