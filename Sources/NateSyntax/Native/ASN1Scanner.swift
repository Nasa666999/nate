import Foundation
import NateCore

struct ASN1Scanner {
    let bytes: [UInt8]
    var documentEnd = true
    let rules: ASN1Rules
    var budget: ANSILexingBudget
    var state: ASN1LexicalState
    var cursor = 0
    var emitted = 0
    var previous: UInt32 = 0
    var styles: [UInt8]

    /// 业务作用：ASN.1 保留原生状态分支和消费顺序，OID 内部通道跨物理行独立于当前显示类别。
    /// 参数说明: 无。
    /// 返回：完整原字节类别及后继状态；任一读取、资源或预算不足时整份抛错。
    mutating func scan() throws -> ([UInt8], ASN1LexicalState) {
        while more() {
            try budget.consume()
            let value = try current()
            if state.oid {
                try oidCharacter(value)
            }
            else {
                switch state.mode {
                case 0:
                    try begin()
                case 1:
                    if value == 13 || value == 10 {
                        try setState(0)
                    }
                case 2:
                    if !ASN1Characters.word(value) {
                        try identifier()
                    }
                case 3:
                    if value == 34 {
                        try forward()
                        try setState(0)
                        try begin()
                    }
                case 5:
                    if !ASN1Characters.digit(value) {
                        try setState(0)
                    }
                case 10:
                    if value == 123 {
                        state.oid = true
                        try oidCharacter(value)
                    }
                    else if ASN1Characters.digit(value) {
                        try trapNumber()
                    }
                    else if ![58, 61, 32].contains(value) {
                        try begin()
                    }
                default:
                    throw NateError.message("ASN.1 连续状态缺少有效原生通道。")
                }
            }
            try forward()
        }
        try setState(state.mode)
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：只有真实当前标量可开启注释、字面、数值或名称；原生操作符回退保留未识别字符的原类别。
    /// 参数说明: 无。
    /// 返回：适用的原生通道已经开启，其它输入保持当前类别；预算不足时抛错。
    mutating func begin() throws {
        let value = try current()
        if try value == 45 && next() == 45 {
            try setState(1)
        }
        else if value == 34 {
            try setState(3)
        }
        else if ASN1Characters.digit(value) {
            try setState(5)
        }
        else if ASN1Characters.word(value) {
            try setState(2)
        }
        else if value == 58 {
            try setState(10)
        }
    }

    /// 业务作用：名称结束后按原生四组优先级确认类别，当前终止标量不重复解释为新的开端。
    /// 参数说明: 无。
    /// 返回：完整名称取得关键词、属性、描述符、类型或普通名称类别，随后进入默认通道。
    mutating func identifier() throws {
        let end = min(cursor, emitted + 99)
        guard emitted >= 0, end >= emitted, end <= bytes.count else {
            throw NateError.invalidRange
        }
        for _ in emitted..<end {
            try budget.consume()
        }
        let candidate = Data(bytes[emitted..<end])
        for group in 0..<4 {
            if try rules.contains(candidate, group: group, budget: &budget) {
                state.mode = UInt8(group + 6)
                break
            }
        }
        try setState(0)
    }

    /// 业务作用：OID 内的名称不查询关键词，数字依照紧邻原生标量取得独立 OID 类别，首个右花括号结束通道。
    /// 参数说明:
    /// - value: 当前完整原文标量。
    /// 返回：当前标量的原生类别已确认，实际右花括号解除 OID 通道；预算不足时抛错。
    mutating func oidCharacter(_ value: UInt32) throws {
        if ASN1Characters.digit(value) && (!ASN1Characters.word(previous) || ASN1Characters.digit(previous)) {
            try setState(4)
        }
        else if ASN1Characters.word(value) {
            try setState(2)
        }
        else {
            try setState(0)
        }
        if value == 125 {
            state.oid = false
        }
    }

    /// 业务作用：赋值后的 trap 数字采用原生 OID 类别，结束字符由外层步进消费而不再授予开端资格。
    /// 参数说明: 无。
    /// 返回：完整 trap 数字已收束，真实 EOF 或分隔符保持原生消费顺序；预算不足时抛错。
    mutating func trapNumber() throws {
        while more() {
            if ASN1Characters.digit(try current()) {
                try setState(4)
                try forward()
            }
            else {
                try setState(0)
                break
            }
        }
    }
}
