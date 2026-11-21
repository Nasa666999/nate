import Foundation

enum MarkupTagStage {
    case name, beforeAttribute, attribute, afterAttribute, beforeValue, quoted, afterValue, unquoted,
        selfClosing
}

struct MarkupTag {
    let dialect: MarkupDialect
    var closing = false
    var stage = MarkupTagStage.name
    var name: [UInt8] = []
    var attribute: [UInt8] = []
    var resolvedName: String?
    var quote: UInt8 = 0
    var valid = true
    var capacityExceeded = false

    /// 业务作用：属性引号与自闭合分别传播，只有真正的标签结束符才结束当前结构。
    /// 参数说明:
    /// - byte: 当前原始 UTF-8 字节。
    /// 返回：当前字节结束标签时为真；非法或未完成内容继续保留为不生成闭合符的状态。
    mutating func consume(_ byte: UInt8) -> Bool {
        switch stage {
        case .name:
            if Self.whitespace(byte) || byte == 47 || byte == 62 {
                resolvedName = MarkupNames.validated(name, dialect: dialect)
                valid = valid && resolvedName != nil
                stage = .beforeAttribute
                return consume(byte)
            }
            if name.count < 4096 {
                name.append(byte)
            }
            else {
                valid = false
                capacityExceeded = true
            }
        case .beforeAttribute:
            if byte == 62 {
                return true
            }
            if byte == 47 {
                stage = .selfClosing
            }
            else if !Self.whitespace(byte) {
                if closing {
                    valid = false
                }
                attribute = []
                stage = .attribute
                return consume(byte)
            }
        case .attribute:
            if Self.whitespace(byte) || byte == 61 || byte == 47 || byte == 62 {
                valid = valid && MarkupNames.attributeValidated(attribute, dialect: dialect)
                stage = .afterAttribute
                return consume(byte)
            }
            if attribute.count < 4096 {
                attribute.append(byte)
            }
            else {
                valid = false
                capacityExceeded = true
            }
        case .afterAttribute:
            if byte == 61 {
                stage = .beforeValue
            }
            else if !Self.whitespace(byte) {
                if dialect == .xml {
                    valid = false
                }
                stage = .beforeAttribute
                return consume(byte)
            }
        case .beforeValue:
            if byte == 34 || byte == 39 {
                quote = byte
                stage = .quoted
            }
            else if !Self.whitespace(byte) {
                if dialect == .xml || byte == 62 {
                    valid = false
                }
                stage = .unquoted
                return consume(byte)
            }
        case .quoted:
            if byte == quote {
                quote = 0
                stage = .afterValue
            }
            else if byte == 60 && dialect == .xml {
                valid = false
            }
        case .afterValue:
            if Self.whitespace(byte) {
                stage = .beforeAttribute
            }
            else if byte == 47 || byte == 62 {
                stage = .beforeAttribute
                return consume(byte)
            }
            else {
                valid = false
                stage = .beforeAttribute
                return consume(byte)
            }
        case .unquoted:
            if byte == 62 {
                return true
            }
            if Self.whitespace(byte) {
                stage = .beforeAttribute
            }
            else if [34, 39, 60, 61, 96, 0].contains(byte) {
                valid = false
            }
        case .selfClosing:
            if byte == 62 {
                return true
            }
            if dialect == .html {
                stage = .beforeAttribute
                return consume(byte)
            }
            // XML 的斜杠必须紧邻结束符；含其它内容时不能按自闭合或普通标签猜测补全。
            valid = false
        }
        if byte == 0 || byte == 12 && dialect == .xml {
            valid = false
        }
        return false
    }

    /// 业务作用：名称和属性之间只接受标记语法明确规定的 ASCII 空白。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：空格、Tab、LF、CR 或 HTML FF 时为真。
    static func whitespace(_ byte: UInt8) -> Bool {
        [9, 10, 12, 13, 32].contains(byte)
    }
}
