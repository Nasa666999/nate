import Foundation
import NateCore

public struct FunctionRule: Sendable {
    public let expression: String
    public let nameExpressions: [String]
    public let classExpressions: [String]
    public let displayMode: String?
}

public struct ClassRule: Sendable {
    public let expression: String
    public let nameExpressions: [String]
    public let openingExpression: String?
    public let closingExpression: String?
    public let function: FunctionRule
    public let displayMode: String?
}

public struct FunctionListDefinition: Sendable {
    public let id: String
    public let displayName: String
    public let commentExpression: String?
    public let classRule: ClassRule?
    public let functionRule: FunctionRule?
    public let originalXML: Data
    public let notices: [String]

    /// 业务作用：独立解析函数列表 XML，保留逐层名称规则、类边界及原定义。
    /// 参数说明:
    /// - data: 不含外部实体的完整规则 XML。
    /// 返回：不可变规则；缺少主表达式或存在半套类边界时拒绝。
    public init(data: Data) throws {
        let root = try ResourceXML.parse(data)
        guard root.name == "NotepadPlus",
            let list = root.children.first(where: {
                $0.name == "functionList"
            }),
            let parser = list.children.first(where: {
                $0.name == "parser"
            }),
            let identifier = parser.attributes["id"], !identifier.isEmpty
        else {
            throw NateError.message("函数列表资源缺少 NotepadPlus / functionList / parser 或 id。")
        }
        guard
            list.children.filter({
                $0.name == "parser"
            }).count == 1,
            parser.children.filter({
                $0.name == "function"
            }).count <= 1,
            parser.children.filter({
                $0.name == "classRange"
            }).count <= 1
        else {
            throw NateError.message("函数列表只能声明一个 parser、一个全局函数规则和一个类规则。")
        }
        id = identifier
        displayName = parser.attributes["displayName"] ?? identifier
        commentExpression = parser.attributes["commentExpr"].flatMap {
            $0.isEmpty ? nil : $0
        }
        functionRule = try parser.children.first(where: {
            $0.name == "function"
        }).map {
            try Self.function($0)
        }
        if let node = parser.children.first(where: {
            $0.name == "classRange"
        }) {
            let opening = node.attributes["openSymbole"].flatMap {
                $0.isEmpty ? nil : $0
            }
            let closing = node.attributes["closeSymbole"].flatMap {
                $0.isEmpty ? nil : $0
            }
            guard (opening == nil) == (closing == nil),
                let function = node.children.first(where: {
                    $0.name == "function"
                })
            else {
                throw NateError.message("类规则需要完整边界对及类内函数规则。")
            }
            classRule = try ClassRule(
                expression: Self.expression(node, key: "mainExpr"),
                nameExpressions: Self.names(node, container: "className", item: "nameExpr"),
                openingExpression: opening,
                closingExpression: closing,
                function: Self.function(function, nested: true),
                displayMode: node.attributes["displayMode"]
            )
        }
        else {
            classRule = nil
        }
        guard classRule != nil || functionRule != nil else {
            throw NateError.message("函数列表没有类或函数主规则。")
        }
        originalXML = data
        notices = Self.unknownFields(parser)
    }

    /// 业务作用：装配单位函数的逐层名称提取规则，类内规则使用独立的 funcNameExpr 元素。
    /// 参数说明:
    /// - node: function 节点。
    /// - nested: 是否为类内函数规则。
    /// 返回：完整单位规则，不把不存在的名称链当作空匹配。
    static func function(_ node: ResourceXMLNode, nested: Bool = false) throws -> FunctionRule {
        try FunctionRule(
            expression: expression(node, key: "mainExpr"),
            nameExpressions: names(
                node,
                container: "functionName",
                item: nested ? "funcNameExpr" : "nameExpr"
            ),
            classExpressions: names(node, container: "className", item: "nameExpr"),
            displayMode: node.attributes["displayMode"]
        )
    }

    /// 业务作用：读取必需表达式，防止空规则被解释为每个字符边界的命中。
    /// 参数说明:
    /// - node: 当前规则节点。
    /// - key: 表达式属性名。
    /// 返回：非空规则文本；缺失时失败。
    static func expression(_ node: ResourceXMLNode, key: String) throws -> String {
        guard let value = node.attributes[key], !value.isEmpty else {
            throw NateError.message("函数列表节点 \(node.name) 缺少 \(key)。")
        }
        return value
    }

    /// 业务作用：保留名称表达式的声明顺序，每一层都约束在上一层的命中内。
    /// 参数说明:
    /// - node: 类或函数规则节点。
    /// - container: 名称容器元素。
    /// - item: 该容器内合法的表达式元素。
    /// 返回：有序规则；单个名称最多允许 64 层。
    static func names(_ node: ResourceXMLNode, container: String, item: String) throws -> [String] {
        let children =
            node.children.first(where: {
                $0.name == container
            })?.children ?? []
        guard children.count <= 64 else {
            throw NateError.message("函数列表名称提取超过 64 层。")
        }
        return try children.filter {
            $0.name == item
        }.map {
            try expression($0, key: "expr")
        }
    }

    /// 业务作用：报告当前解释器未消费的字段，原 XML 保留它们以供导出和后续解释。
    /// 参数说明:
    /// - node: 当前资源节点。
    /// 返回：稳定排序的字段路径，不改写资源正文。
    static func unknownFields(_ node: ResourceXMLNode) -> [String] {
        let attributes: [String: Set<String>] = [
            "parser": ["id", "displayName", "commentExpr"],
            "classRange": ["mainExpr", "openSymbole", "closeSymbole", "displayMode"],
            "function": ["mainExpr", "displayMode"],
            "className": [], "functionName": [], "nameExpr": ["expr"], "funcNameExpr": ["expr"],
        ]
        var result = node.attributes.keys.filter {
            !(attributes[node.name] ?? []).contains($0)
        }
        .map {
            node.name + "/@" + $0
        }
        for child in node.children {
            if attributes[child.name] == nil {
                result.append(node.name + "/" + child.name)
            }
            else {
                result += unknownFields(child)
            }
        }
        return result.sorted()
    }
}
