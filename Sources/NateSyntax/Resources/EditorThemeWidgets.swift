import Foundation
import NateCore

extension EditorThemeXMLReader {
    /// 业务作用：整体配色只映射到对应界面角色，独立标记设置、标签及未对应部件保持明确兼容说明。
    /// 参数说明:
    /// - row: 当前完整 WidgetStyle 节点。
    /// 返回：可解释的整体颜色与默认字体进入主题，未知或尚无对应部件的字段逐项报告。
    mutating func readWidget(_ row: ResourceXMLNode) throws {
        try check()
        guard row.name == "WidgetStyle", let name = row.attributes["name"] else {
            throw NateError.message("整体配色项缺少 WidgetStyle 或 name。")
        }
        let value = try style(row)
        for attribute in row.attributes.keys.sorted()
        where !["name", "styleID", "fgColor", "bgColor", "fontName", "fontSize", "fontStyle", "colorStyle"]
            .contains(attribute)
        {
            report("未应用界面字段：" + label(name) + " / " + label(attribute))
        }
        if !row.children.isEmpty || !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report("界面项扩展内容未应用：" + label(name))
        }
        if name == "Default Style" {
            guard kinds["text"] == nil else {
                throw NateError.message("主题含重复默认样式，未采用部分内容。")
            }
            kinds["text"] = value
            if let color = value.foreground {
                colors["foreground"] = color
            }
            if let color = value.background {
                colors["background"] = color
            }
            count += 1
            return
        }
        let mapping: [String: (EditorThemeColorRole?, EditorThemeColorRole?)] = [
            "Caret colour": (.caret, nil),
            "Selected text colour": (.selectionForeground, .selectionBackground),
            "Current line background colour": (nil, .currentLineBackground),
            "Line number margin": (.lineNumber, .gutterBackground),
            "White space symbol": (.whitespace, nil),
            "Non-printing characters custom color": (.whitespace, nil),
            "Indent guideline style": (.indentGuide, nil),
            "Edge colour": (.longLineGuide, nil),
            "Brace highlight style": (nil, .bracketMatchBackground),
            "Bad brace colour": (nil, .bracketMismatchBackground),
            "Fold": (.foldMarker, nil),
            "Change History modified": (.modificationUnsaved, nil),
            "Change History saved": (.modificationSaved, nil),
            "URL hovered": (.linkForeground, nil),
        ]
        guard let (foreground, background) = mapping[name] else {
            report("未映射的界面配色项：" + label(name))
            return
        }
        if let foreground, let color = value.foreground {
            colors[foreground.rawValue] = color
        }
        if let background, let color = value.background {
            colors[background.rawValue] = color
        }
        if foreground == nil, value.foreground != nil {
            report("界面项前景字段未映射：" + label(name))
        }
        if background == nil, value.background != nil {
            report("界面项背景字段未映射：" + label(name))
        }
        if value.fontName != nil || value.fontSize != nil || value.fontStyle != nil {
            report("界面项字体字段未映射：" + label(name))
        }
        count += 1
    }
}
