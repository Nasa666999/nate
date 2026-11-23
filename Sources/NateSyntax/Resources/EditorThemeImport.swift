import Foundation
import NateCore

public struct EditorThemeImportResult: Sendable {
    public let definition: EditorThemeDefinition
    public let reports: [String]
    public let omittedReportCount: Int
}

public enum EditorThemeImport {
    /// 业务作用：主题导入区分独立 Nate JSON 与 Notepad++ 配色 XML，完整解析后才提供可应用定义。
    /// 参数说明:
    /// - data: 最多 8 MiB 的完整主题原字节。
    /// - name: XML 没有独立名称时采用的明确名称。
    /// - languages: 当前已安装的稳定语言身份，用于报告尚无对应语言的样式。
    /// - permit: 当前读取、解析与应用意图仍然有效。
    /// 返回：全部有效定义与有限兼容说明；未知协议、非法字段或超量整体拒绝。
    public static func parse(
        _ data: Data,
        name: String,
        languages: Set<String>,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> EditorThemeImportResult {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard data.count <= 8 * 1024 * 1024 else {
            throw NateError.message("主题导入文件超过 8 MiB。")
        }
        let start = data.starts(with: [239, 187, 191]) ? data.dropFirst(3) : data[...]
        let first = start.first(where: {
            ![9, 10, 13, 32].contains($0)
        })
        if first == 123 {
            let definition = try EditorThemeCodec.decode(data, permit: permit)
            return EditorThemeImportResult(
                definition: definition,
                reports: retainedRoleReports(definition),
                omittedReportCount: 0
            )
        }
        guard first == 60 else {
            throw NateError.message("主题须为完整 Nate JSON 或 Notepad++ 配色 XML。")
        }
        var reader = EditorThemeXMLReader(name: name, languages: languages, permit: permit)
        return try reader.parse(data)
    }

    /// 业务作用：尚无对应绘制的整体角色保留定义并明确说明，导入成功不代表所有外部部件均已呈现。
    /// 参数说明:
    /// - definition: 已完整校验且可保留的主题。
    /// 返回：当前只保存、不改变界面的有限角色说明。
    static func retainedRoleReports(_ definition: EditorThemeDefinition) -> [String] {
        let roles: [EditorThemeColorRole] = [
            .linkForeground
        ]
        return roles.compactMap {
            definition.colors[$0.rawValue] == nil ? nil : "配色定义已保留，当前尚无对应绘制：" + $0.rawValue
        }
    }
}

struct EditorThemeXMLReader {
    let name: String
    let languages: Set<String>
    let permit: @Sendable () -> Bool
    var colors: [String: String] = [:]
    var kinds: [String: EditorThemeStyle] = [:]
    var styles: [String: [String: EditorThemeStyle]] = [:]
    var reports: [String] = []
    var reportCount = 0
    var count = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))

    /// 业务作用：受限 XML 完整树逐项转换为独立配色，关键字文字与界面专属项不被误当成语言规则。
    /// 参数说明:
    /// - data: 已通过原文件容量检查的完整 XML。
    /// 返回：全部已知样式和兼容说明，根结构或有效字段损坏时整份拒绝。
    mutating func parse(_ data: Data) throws -> EditorThemeImportResult {
        let root = try ResourceXML.parse(data)
        guard root.name == "NotepadPlus" else {
            throw NateError.message("配色 XML 没有 NotepadPlus 根节点。")
        }
        for group in root.children {
            try check()
            if group.name == "LexerStyles" {
                for lexer in group.children {
                    try readLexer(lexer)
                }
            }
            else if group.name == "GlobalStyles" {
                for widget in group.children {
                    try readWidget(widget)
                }
            }
            else {
                report("未应用主题节点：" + label(group.name))
            }
        }
        guard count > 0 else {
            throw NateError.message("配色 XML 没有可解释的完整样式，当前主题保留。")
        }
        let definition = try EditorThemeDefinition(
            name: name,
            colors: colors,
            kindStyles: kinds,
            languageStyles: styles
        )
        for message in EditorThemeImport.retainedRoleReports(definition) {
            report(message)
        }
        _ = try EditorThemeSnapshot(definition)
        try check()
        return EditorThemeImportResult(
            definition: definition,
            reports: reports,
            omittedReportCount: max(0, reportCount - reports.count)
        )
    }

    /// 业务作用：每个原生样式编号在所属语言内保持唯一，主题关键字内容不取得词法资源写入权。
    /// 参数说明:
    /// - lexer: 当前语言的完整样式容器。
    /// 返回：有效数字类别与属性进入对应语言；未知语言保留定义并报告。
    mutating func readLexer(_ lexer: ResourceXMLNode) throws {
        try check()
        guard lexer.name == "LexerType", let language = lexer.attributes["name"],
            !language.isEmpty, language.utf8.count <= 256
        else {
            throw NateError.message("配色 XML 的语言容器缺少有限的 name 字段。")
        }
        if !languages.contains(language) {
            report("样式语言当前未安装，定义保留：" + label(language))
        }
        for attribute in lexer.attributes.keys.sorted()
        where !["name", "desc", "ext"].contains(attribute) {
            report("未应用语言字段：" + label(language) + " / " + label(attribute))
        }
        for row in lexer.children {
            try check()
            guard row.name == "WordsStyle" else {
                report("未应用语言样式节点：" + label(language) + " / " + label(row.name))
                continue
            }
            guard let raw = row.attributes["styleID"],
                let identifier = UInt8(raw)
            else {
                throw NateError.message("配色语言样式缺少零至二百五十五的完整 styleID。")
            }
            let key = "style:" + String(identifier)
            guard styles[language]?[key] == nil else {
                throw NateError.message("同一语言出现重复主题样式编号，未采用部分内容。")
            }
            let value = try style(row)
            styles[language, default: [:]][key] = value
            count += 1
            guard count <= 8192, styles.count <= 512 else {
                throw NateError.message("主题 XML 超过 8192 项或 512 种语言。")
            }
            if !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report("主题中的关键字文字未改变语言词表：" + label(language) + " / " + key)
            }
            for attribute in row.attributes.keys.sorted()
            where ![
                "name", "styleID", "fgColor", "bgColor", "fontName", "fontSize", "fontStyle", "colorStyle",
                "keywordClass",
            ].contains(attribute) {
                report("未应用样式字段：" + label(language) + " / " + label(attribute))
            }
            if !row.children.isEmpty {
                report("样式的扩展子节点未应用：" + label(language) + " / " + key)
            }
        }
    }

    /// 业务作用：主题配色及字体字段按明确继承规则转换，非法颜色或装饰不能静默变成另一种样式。
    /// 参数说明:
    /// - row: 当前完整样式节点。
    /// 返回：合法颜色和字体的独立覆盖值，字段损坏时拒绝整份主题。
    func style(_ row: ResourceXMLNode) throws -> EditorThemeStyle {
        let fields = row.attributes
        let mask: Int
        if let raw = fields["colorStyle"], !raw.isEmpty {
            guard let value = Int(raw), (0...3).contains(value) else {
                throw NateError.message("主题 colorStyle 须为零至三的完整颜色选择。")
            }
            mask = value
        }
        else {
            mask = 3
        }
        let foreground = try mask & 1 == 0 ? nil : rgb(fields["fgColor"])
        let background = try mask & 2 == 0 ? nil : rgb(fields["bgColor"])
        let font = fields["fontName"].flatMap {
            $0.isEmpty ? nil : $0
        }
        let size = try integer(fields["fontSize"], range: 1...512, zeroInherits: true)
        let decoration = try integer(fields["fontStyle"], range: 0...7, zeroInherits: false)
        return try EditorThemeStyle(
            foreground: foreground,
            background: background,
            fontName: font,
            fontSize: size,
            fontStyle: decoration
        )
    }

    /// 业务作用：XML 六位 RGB 转换为主题统一颜色；空字段和明确继承标记不生成覆盖。
    /// 参数说明:
    /// - raw: 当前原始颜色属性。
    /// 返回：合法六位 RGB 或继承值；非法非空颜色拒绝。
    func rgb(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty, raw != "-1", raw.uppercased() != "FFFFFFFF" else {
            return nil
        }
        guard raw.utf8.count == 6 else {
            throw NateError.message("主题 XML 颜色须为六位 RGB 或继承值。")
        }
        return try EditorThemeStyle.canonicalColor("#" + raw)
    }

    /// 业务作用：字体字段区分继承与明确的零装饰，范围以外的数值不会被夹取。
    /// 参数说明:
    /// - raw: 当前原始数值字段。
    /// - range: 当前属性的合法范围。
    /// - zeroInherits: 当前属性的零值是否表示继承。
    /// 返回：合法明确整数或继承值，非法拼写与越界整体拒绝。
    func integer(_ raw: String?, range: ClosedRange<Int>, zeroInherits: Bool) throws -> Int? {
        guard let raw, !raw.isEmpty, raw != "-1", !(zeroInherits && raw == "0") else {
            return nil
        }
        guard raw.utf8.count <= 4, let value = Int(raw), range.contains(value) else {
            throw NateError.message("主题 XML 的字体数值字段不合法。")
        }
        return value
    }

    /// 业务作用：兼容说明有界保留，很多未知字段不能扩大主窗口或错误归档。
    /// 参数说明:
    /// - value: 当前已经受限的单项说明。
    /// 返回：至多保存 128 项，额外数量仍供界面明确报告。
    mutating func report(_ value: String) {
        reportCount += 1
        if reports.count < 128 {
            reports.append(value)
        }
    }

    /// 业务作用：外部节点名称只进入有限展示，避免把超长未知标签复制到说明列表。
    /// 参数说明:
    /// - value: 当前原始字段名或样式标签。
    /// 返回：最多八十个可见标量的说明标签。
    func label(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(80)))
    }

    /// 业务作用：主题转换、字段遍历和发布沿共同截止响应取消，不返回部分有效配色。
    /// 参数说明: 无。
    /// 返回：当前任务仍有效时继续，取消或超时整体拒绝。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("完整主题转换超过五秒，当前主题保留。")
        }
    }
}
