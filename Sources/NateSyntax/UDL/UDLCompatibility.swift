import Foundation
import NateCore

enum UDLCompatibility {
    static let attributes: [String: Set<String>] = [
        "NotepadPlus": [],
        "UserLang": ["name", "ext", "udlVersion", "darkModeTheme"],
        "Settings": [],
        "Global": ["caseIgnored", "allowFoldOfComments", "foldCompact", "forcePureLC", "decimalSeparator"],
        "Prefix": Set(
            (1...8).map {
                "Keywords\($0)"
            }
        ),
        "KeywordLists": [],
        "Keywords": ["name"],
        "Styles": [],
        "WordsStyle": [
            "name", "fgColor", "bgColor", "colorStyle", "fontStyle", "fontName", "fontSize", "nesting",
        ],
    ]
    static let lists: Set<String> = keywordListNames()
    static let styles: Set<String> = styleNames()

    /// 业务作用：明确列出当前会执行的 UDL 规则组，未应用的名称必须进入兼容说明。
    /// 参数说明: 无。
    /// 返回：注释、分隔符、运算符、八组关键字、数字与折叠规则的完整名称集合。
    private static func keywordListNames() -> Set<String> {
        var names: Set<String> = ["Comments", "Delimiters", "Operators1", "Operators2"]
        for group in 1...8 {
            names.insert("Keywords\(group)")
        }
        for part in ["prefix1", "prefix2", "extras1", "extras2", "suffix1", "suffix2", "range"] {
            names.insert("Numbers, " + part)
        }
        for family in ["Folders in code1", "Folders in code2", "Folders in comment"] {
            for action in ["open", "middle", "close"] {
                names.insert(family + ", " + action)
            }
        }
        return names
    }

    /// 业务作用：样式识别与有效词法组保持一致，未知样式原文保留并提供明确说明。
    /// 参数说明: 无。
    /// 返回：基础样式、八组关键字和八组分隔符的完整名称集合。
    private static func styleNames() -> Set<String> {
        var names: Set<String> = [
            "DEFAULT", "COMMENTS", "LINE COMMENTS", "NUMBERS", "OPERATORS", "FOLDER IN CODE1",
            "FOLDER IN CODE2", "FOLDER IN COMMENT",
        ]
        for group in 1...8 {
            names.insert("KEYWORDS\(group)")
            names.insert("DELIMITERS\(group)")
        }
        return names
    }

    /// 业务作用：只有对应容器中的已知节点能改变有效规则，扩展子树不能借嵌套字段取得配置权限。
    /// 参数说明:
    /// - element: 当前节点名。
    /// - parent: 实际父节点，为空时处于文档根。
    /// 返回：节点位于明确支持的语义位置时为真。
    static func permits(_ element: String, parent: String?) -> Bool {
        switch element {
        case "NotepadPlus": return parent == nil
        case "UserLang": return parent == nil || parent == "NotepadPlus"
        case "Settings", "KeywordLists", "Styles": return parent == "UserLang"
        case "Global", "Prefix": return parent == "Settings"
        case "Keywords": return parent == "KeywordLists"
        case "WordsStyle": return parent == "Styles"
        default: return false
        }
    }

    /// 业务作用：逐字段报告未应用的属性、规则组和样式，保留完整原 XML 供用户检查与导出。
    /// 参数说明:
    /// - element: 当前已确认位置的节点名。
    /// - values: XML 解码后的原属性。
    /// - path: 实际节点路径。
    /// 返回：稳定顺序的具体兼容说明；已知布尔或颜色选择字段无效时拒绝完整定义。
    static func messages(element: String, values: [String: String], path: String) throws -> [String] {
        if element == "Keywords" || element == "WordsStyle" {
            guard let name = values["name"], !name.isEmpty, name.utf8.count <= 200 else {
                throw NateError.message("UDL 节点 \(path) 缺少有效 name，或名称超过 200 UTF-8 字节。")
            }
        }
        let allowed = attributes[element] ?? []
        var messages: [String] = []
        for key in values.keys.sorted() where !allowed.contains(key) {
            messages.append("未应用字段 \(path)/@\(key)；原 XML 已保留。")
        }
        let booleans: [String]
        switch element {
        case "Global": booleans = ["caseIgnored", "allowFoldOfComments", "foldCompact"]
        case "Prefix":
            booleans = (1...8).map {
                "Keywords\($0)"
            }
        case "UserLang": booleans = ["darkModeTheme"]
        default: booleans = []
        }
        for key in booleans {
            if let value = values[key], value != "yes" && value != "no" {
                throw NateError.message("UDL 字段 \(path)/@\(key) 必须为 yes 或 no。")
            }
        }
        if element == "Keywords", let name = values["name"], !lists.contains(name) {
            messages.append("未应用规则组 \(path)[\(name)]；原 XML 已保留。")
        }
        if element == "WordsStyle" {
            if let name = values["name"], !styles.contains(name) {
                messages.append("未应用样式 \(path)[\(name)]；原 XML 已保留。")
            }
            for key in ["fontName", "fontSize"] {
                if let value = values[key], !value.isEmpty, !(key == "fontSize" && value == "0") {
                    messages.append("\(path)/@\(key) 当前继承编辑器字体；显式值仅保留在原 XML。")
                }
            }
            if let value = values["colorStyle"],
                Int(value).map({
                    (0...3).contains($0)
                }) != true
            {
                throw NateError.message("UDL 字段 \(path)/@colorStyle 必须为 0 至 3。")
            }
            if let value = values["nesting"], let mask = UInt32(value), mask & 0xF8000000 != 0 {
                messages.append("\(path)/@nesting 含未应用的位集合 \(mask & 0xF8000000)；已知位继续按各自规则生效，原 XML 已保留。")
            }
        }
        if element == "UserLang", values["darkModeTheme"] != nil {
            messages.append("\(path)/@darkModeTheme 保留为来源信息；颜色按当前 macOS 外观呈现，用户语言不自动成对切换。")
        }
        return messages
    }

    /// 业务作用：无效编号不能取得规则权限，完整 UTF-8 标记的增强行为保留逐项说明。
    /// 参数说明:
    /// - word: 当前完整原字段。
    /// - list: 实际注释或分隔符规则组。
    /// - position: 该组内保留候选包装后的有序位置。
    /// - path: 当前 XML 节点的实际路径。
    /// 返回：编号非法或使用超出原字符范围的标记时给出单项说明，其它有效字段不产生说明。
    static func indexedMessage(word: String, list: String, position: Int, path: String) -> String? {
        let maximum: Int
        switch list {
        case "Comments": maximum = 4
        case "Delimiters": maximum = 23
        default: return nil
        }
        if let indexed = UDLIndexedRule.parse(word, maximum: maximum) {
            if indexed.body.unicodeScalars.contains(where: {
                $0.value > 255
            }) {
                return
                    "\(path)[\(list)]/token[\(position + 1)] 使用完整 UTF-8 标记匹配；超过码点 255 的内容属于 Nate 增强行为，原 XML 已保留。"
            }
            return nil
        }
        return
            "未应用编号字段 \(path)[\(list)]/token[\(position + 1)]；编号须为两位 ASCII 数字且位于 00–\(String(format: "%02d", maximum))，原 XML 已保留。"
    }
}
