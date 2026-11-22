import Foundation

struct SQLFoldState {
    static let nested: UInt32 = 0x0001ff
    static let select: UInt32 = 0x000200
    static let withoutWhen: UInt32 = 0x000400
    static let merge: UInt32 = 0x000800
    static let declare: UInt32 = 0x001000
    static let exception: UInt32 = 0x002000
    static let condition: UInt32 = 0x004000
    static let ignoreWhen: UInt32 = 0x008000
    static let create: UInt32 = 0x010000
    static let view: UInt32 = 0x020000
    static let viewAs: UInt32 = 0x040000
    var flags: UInt32 = 0
    var current = 1024
    var next = 1024
    var endFound = false
    var statementFound = false

    /// 业务作用：SQL 折叠关键字沿条件、CASE、MERGE 和视图语句的实际状态推进。
    /// 参数说明:
    /// - word: 最多九字节且完整终止的 ASCII 小写关键字。
    /// 返回：当前行和后继行的层级及语句标志同步推进，不产生正文副作用。
    mutating func keyword(_ word: String) {
        switch word {
        case "select":
            flags |= Self.select
        case "if":
            if endFound {
                endFound = false
            }
            else {
                flags |= Self.condition
                current = min(current, next)
            }
        case "then" where flags & Self.condition != 0:
            flags &= ~Self.condition
            current = min(current, next)
            if !statementFound {
                next += 1
            }
            statementFound = true
        case "loop", "case":
            if endFound {
                endFound = false
                if word == "case" {
                    if flags & Self.nested > 0 {
                        flags -= 1
                    }
                    if flags & Self.withoutWhen == 0 {
                        next -= 1
                    }
                }
            }
            else {
                if word == "case" {
                    if flags & Self.nested < Self.nested {
                        flags += 1
                    }
                    flags |= Self.withoutWhen
                }
                current = min(current, next)
                if !statementFound {
                    next += 1
                }
                statementFound = true
            }
        case "begin":
            next += 1
            flags &= ~Self.declare
        case "end", "endif":
            endFound = true
            next -= 1
            if flags & Self.select != 0, flags & Self.withoutWhen == 0 {
                next -= 1
            }
            next = max(1024, next)
        case "when"
        where flags & Self.ignoreWhen == 0 && flags & Self.exception == 0
            && flags & (Self.nested | Self.merge) != 0:
            flags |= Self.condition
            if !statementFound {
                if flags & Self.withoutWhen == 0 {
                    current -= 1
                    next -= 1
                }
                flags &= ~Self.withoutWhen
            }
        case "exit":
            flags |= Self.ignoreWhen
        case "exception" where flags & Self.declare == 0:
            flags |= Self.exception
        case "declare", "function", "procedure", "package":
            flags |= Self.declare
        case "merge":
            flags |= Self.merge | Self.withoutWhen
            next += 1
            statementFound = true
        case "create":
            flags |= Self.create
        case "view" where flags & Self.create != 0:
            flags |= Self.view
        case "as" where flags & Self.view != 0 && flags & Self.viewAs == 0:
            flags |= Self.viewAs
            next += 1
        default:
            break
        }
    }

    /// 业务作用：实际行尾或非注释分号解除 END 的临时资格，分号收束 MERGE 与 CREATE VIEW 语句。
    /// 参数说明:
    /// - semicolon: 当前是否为非注释分号。
    /// 返回：临时结束标志清空；分号同时释放已开启语句的折叠层级。
    mutating func boundary(semicolon: Bool) {
        if endFound {
            flags &= ~Self.exception
        }
        endFound = false
        if !semicolon {
            return
        }
        if flags & Self.merge != 0 {
            if flags & Self.withoutWhen == 0 {
                next -= 1
            }
            flags &= ~Self.merge
            next -= 1
        }
        flags &= ~Self.select
        if flags & Self.create != 0 {
            if flags & Self.view != 0 {
                if flags & Self.viewAs != 0 {
                    next -= 1
                    flags &= ~Self.viewAs
                }
                flags &= ~Self.view
            }
            flags &= ~Self.create
        }
    }
}
