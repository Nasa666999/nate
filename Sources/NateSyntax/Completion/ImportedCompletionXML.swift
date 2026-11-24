import Foundation
import NateCore

enum ImportedCompletionXML {
    /// 业务作用：用户 XML 只有一个有效词表与可选的单个环境，任何字段变化先验证再提供给补全运行时。
    /// 参数说明:
    /// - root: 无外部实体、已受规模限制的完整 XML。
    /// 返回：唯一且全部字段符合补全格式的 AutoComplete 节点；有歧义或不支持时拒绝。
    static func validate(_ root: ResourceXMLNode) throws -> ResourceXMLNode {
        guard root.name == "NotepadPlus", root.children.count == 1,
            let complete = root.children.first, complete.name == "AutoComplete"
        else {
            throw NateError.message("补全 XML 必须包含唯一的 NotepadPlus / AutoComplete。")
        }
        try validateFields(root, allowing: [])
        try validateFields(complete, allowing: ["language"])
        let environments = complete.children.filter { $0.name == "Environment" }
        guard environments.count <= 1 else {
            throw NateError.message("补全 XML 只能包含一个 Environment 节点。")
        }
        let environment = environments.first
        if let environment {
            try validateEnvironment(environment)
        }
        for keyword in complete.children where keyword.name != "Environment" {
            try Task.checkCancellation()
            guard keyword.name == "KeyWord",
                let name = keyword.attributes["name"], !name.isEmpty, name.utf8.count <= 4096,
                keyword.attributes["func"].map({ ["yes", "no"].contains($0) }) != false
            else {
                throw NateError.message("补全 XML 含有无效的 KeyWord 节点、名称或 func 值。")
            }
            // 既有 Lua 和 COBOL 资源包含行内说明，原 XML 继续保留这些内容，签名只来自明确的 Overload。
            try validateFields(keyword, allowing: ["name", "func"], permitsText: true)
            // 独立词表与随包资源使用相同的原顺序。历史定义可省略 func，明确禁用函数的条目不能再声明签名。
            guard keyword.attributes["func"] != "no" || keyword.children.isEmpty else {
                throw NateError.message("明确设为 func=no 的 KeyWord 不能包含 Overload。")
            }
            for overload in keyword.children {
                guard overload.name == "Overload", overload.attributes["retVal"] != nil else {
                    throw NateError.message("函数签名必须使用带 retVal 的 Overload 节点。")
                }
                try validateFields(overload, allowing: ["retVal", "descr"])
                for parameter in overload.children {
                    guard parameter.name == "Param", parameter.attributes["name"] != nil,
                        parameter.children.isEmpty
                    else {
                        throw NateError.message("参数必须使用带 name 的空 Param 节点。")
                    }
                    try validateFields(parameter, allowing: ["name"])
                }
            }
        }
        return complete
    }

    /// 业务作用：函数参数提示按实际单个分隔字符匹配，不能把多个字符悄悄截成第一个。
    /// 参数说明:
    /// - environment: 唯一的可选补全环境节点。
    /// 返回：环境属性及调用分隔规则能完整解释时通过，否则拒绝本次导入。
    private static func validateEnvironment(_ environment: ResourceXMLNode) throws {
        try validateFields(
            environment,
            allowing: [
                "ignoreCase", "startFunc", "stopFunc", "paramSeparator", "terminal", "additionalWordChar",
            ]
        )
        let values = environment.attributes
        let delimiters = [
            values["startFunc"] ?? "(", values["stopFunc"] ?? ")", values["paramSeparator"] ?? ",",
        ]
        let extra = values["additionalWordChar"] ?? ""
        guard environment.children.isEmpty,
            values["ignoreCase"].map({ ["yes", "no"].contains($0) }) != false,
            delimiters.allSatisfy({
                $0.count == 1 && $0.utf8.count <= 64 && $0.first?.isWhitespace == false
            }),
            Set(delimiters).count == 3, extra.utf8.count <= 4096,
            !extra.contains(where: \.isWhitespace)
        else {
            throw NateError.message("补全环境的大小写、额外词字符或函数分隔符配置无效。")
        }
    }

    /// 业务作用：外部资源中无法解释的字段需要用户明确处理，保留现有规则直到完整定义可用。
    /// 参数说明:
    /// - node: 已定位的原始补全 XML 节点。
    /// - keys: 当前节点支持的原始属性名集合。
    /// - permitsText: 既有词项是否允许保留未参与签名的行内说明。
    /// 返回：所有属性及文本位置均受支持时通过。
    private static func validateFields(
        _ node: ResourceXMLNode,
        allowing keys: Set<String>,
        permitsText: Bool = false
    ) throws {
        guard node.attributes.keys.allSatisfy({ keys.contains($0) }),
            permitsText || node.text.allSatisfy(\.isWhitespace)
        else {
            throw NateError.message("补全 XML 节点 \(node.name) 含有无法识别的属性或文本。")
        }
    }
}
