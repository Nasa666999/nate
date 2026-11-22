import Foundation

typealias UDLFoldAction = SyntaxFoldAction

struct UDLFolderMatch {
    let text: String
    let style: String
    let action: UDLFoldAction
}

struct UDLFoldRules {
    let definition: UDLDefinition
    let enabled: Bool
    static let families = [
        (name: "Folders in code1", style: "FOLDER IN CODE1", mask: UInt32(0)),
        (name: "Folders in code2", style: "FOLDER IN CODE2", mask: UInt32(0x40000)),
        (name: "Folders in comment", style: "FOLDER IN COMMENT", mask: UInt32(0x200000)),
    ]
    static let actions = ["open", "middle", "close"]

    /// 业务作用：没有折叠声明的语言保持折叠菜单关闭，前向和整词组共用同一能力判断。
    /// 参数说明:
    /// - definition: 当前固定 UDL 规则代次。
    /// 返回：三组起中止规则的实际可用状态。
    init(definition: UDLDefinition) {
        self.definition = definition
        enabled = Self.families.contains {
            family in
            Self.actions.contains {
                !(definition.lists[family.name + ", " + $0] ?? []).isEmpty
            }
        }
    }

    /// 业务作用：代码前向折叠只在普通代码中按字面执行，整词折叠由统一整词优先级处理。
    /// 参数说明:
    /// - bytes: 当前完整物理行。
    /// - offset: 当前完整标量边界。
    /// - context: 当前上下文身份，为空时才允许前向代码折叠。
    /// - nesting: 当前实际允许的嵌套位集合。
    /// - budget: 所有规则索引和匹配共同持有的预算。
    /// 返回：首个允许的前向起中止标记，运算符优先；超量或失权时抛错。
    func match(
        bytes: [UInt8],
        offset: Int,
        context: String?,
        nesting: UInt32,
        budget: UDLScanBudget
    ) throws -> UDLFolderMatch? {
        guard enabled, context == nil else {
            return nil
        }
        if nesting & 0x1000000 != 0,
            try budget.longest(
                key: "Operators1",
                patterns: definition.lists["Operators1"] ?? [],
                bytes: bytes,
                offset: offset,
                ignoreCase: definition.caseIgnored
            ) != nil
        {
            return nil
        }
        for action in 0..<3 {
            let key = "Folders in code1, " + Self.actions[action]
            if let marker = try budget.longest(
                key: key,
                patterns: definition.lists[key] ?? [],
                bytes: bytes,
                offset: offset,
                ignoreCase: definition.caseIgnored
            ) {
                return UDLFolderMatch(
                    text: marker,
                    style: "FOLDER IN CODE1",
                    action: UDLFoldAction(rawValue: action) ?? .open
                )
            }
        }
        return nil
    }
}
