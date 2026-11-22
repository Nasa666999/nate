import Foundation

extension ObjCLexing {
    /// 业务作用：Objective-C 按完整物理行推进原生状态，续行同时保留预处理、前置标点和 UUID 资格。
    /// 参数说明: 无。
    /// 返回：完整原字节分类与后继状态，预算不足时由调用方丢弃全部局部结果。
    mutating func scan() throws {
        while cursor < bytes.count || documentEnd && cursor == bytes.count {
            try budget.consume()
            if state.mode == 6,
                cursor == 0 || byte(cursor - 1) == 10
                    || byte(cursor - 1) == 13 && byte(cursor) != 10
            {
                // 续行后的普通字符串先确认上一行样式，末尾空行的未闭合类别不能反向覆盖原字节。
                try change(6)
            }
            if byte(cursor) == 92, byte(cursor + 1) == 10 || byte(cursor + 1) == 13 {
                cursor += 1
                if byte(cursor) == 13, byte(cursor + 1) == 10 {
                    cursor += 1
                }
                cursor += 1
                continue
            }
            try terminate()
            // 原生前移可能已到下一物理行；该行尚未读取时保留状态，不能把范围外哨兵计入可见字符。
            if cursor >= bytes.count, !documentEnd {
                break
            }
            if state.mode == 0 {
                try enter()
            }
            if lineEnd {
                state.continuation.previousNonwhite = 32
                state.continuation.visible = 0
                state.continuation.lastUUID = false
            }
            let current = byte(cursor)
            if !Self.space(current) {
                state.continuation.previousNonwhite = current
                state.continuation.visible += 1
            }
            cursor += max(1, width(cursor))
        }
        try change(state.mode)
    }

    /// 业务作用：原生状态在当前边界结束后，同一位置仍可开始后继代码，文档词与未闭合字面整体重分类。
    /// 参数说明: 无。
    /// 返回：完整已扫描片段取得确定类别，闭合符本身保留所属字面或注释样式。
    private mutating func terminate() throws {
        let current = byte(cursor), next = byte(cursor + 1)
        switch state.mode {
        case 10:
            try change(0)
        case 4:
            if !Self.word(current), current != 46 {
                try change(0)
            }
        case 11:
            if !Self.word(current) {
                classifyIdentifier()
                try change(0)
            }
        case 9:
            if lineEnd || current == 47 && (next == 42 || next == 47) {
                try change(0)
            }
        case 1, 3:
            if current == 42, next == 47 {
                cursor += 2
                try change(0)
            }
            else if state.mode == 3, current == 64 || current == 92 {
                try change(17)
            }
        case 2, 15:
            if lineEnd {
                try change(0)
                state.continuation.visible = 0
            }
        case 17:
            if current == 42, next == 47 {
                state.mode = 18
                cursor += 2
                try change(0)
            }
            else if !Self.documentation(current) {
                if !Self.space(current) || !rules.groups[2].contains(candidate(skipping: 1)) {
                    state.mode = 18
                }
                try change(3)
            }
        case 6, 7:
            try terminateQuoted()
        case 14:
            if current == 13 || current == 10 || current == 47 {
                cursor += 1
                try change(0)
            }
            else if current == 92, next == 92 || next == 47 {
                cursor += 1
            }
        case 13:
            if current == 34 {
                cursor += 1
                if next != 34 {
                    try change(0)
                }
            }
        case 8:
            if current == 13 || current == 10 || current == 41 {
                try change(0)
            }
        default:
            break
        }
    }

    /// 业务作用：普通引号只承认原生三种转义，行结束前没有闭合时整段标记为未闭合字面。
    /// 参数说明: 无。
    /// 返回：闭合字符包含在原字面中，续行由外层统一处理。
    private mutating func terminateQuoted() throws {
        let current = byte(cursor), next = byte(cursor + 1)
        if state.mode == 7, lineEnd {
            state.mode = 12
            cursor += 1
            try change(0)
            state.continuation.visible = 0
        }
        else if current == 92 {
            if next == 34 || next == 39 || next == 92 {
                cursor += 1
            }
        }
        else if current == (state.mode == 6 ? 34 : 39) {
            cursor += 1
            try change(0)
        }
        else if lineEnd {
            state.mode = 12
            cursor += 1
            try change(0)
            state.continuation.visible = 0
        }
    }

    /// 业务作用：代码区按 Objective-C 原生顺序进入逐字字符串、数字、名称、注释、正则或预处理。
    /// 参数说明: 无。
    /// 返回：起点及必要前缀进入新状态，结构字符只在确定代码上下文中归类。
    private mutating func enter() throws {
        let current = byte(cursor), next = byte(cursor + 1)
        if current == 64, next == 34 {
            try change(13)
            cursor += 1
        }
        else if (48...57).contains(current) || current == 46 && (48...57).contains(next) {
            try change(state.continuation.lastUUID ? 8 : 4)
            state.continuation.lastUUID = false
        }
        else if Self.word(current) || current == 64 {
            try change(state.continuation.lastUUID ? 8 : 11)
            state.continuation.lastUUID = false
        }
        else if current == 47, next == 42 {
            let documentation = byte(cursor + 2) == 42 || byte(cursor + 2) == 33
            try change(documentation ? 3 : 1)
            cursor += 1
        }
        else if current == 47, next == 47 {
            let documentation = byte(cursor + 2) == 47 || byte(cursor + 2) == 33
            try change(documentation ? 15 : 2)
        }
        else if current == 47, [40, 61, 44].contains(state.continuation.previousNonwhite) {
            try change(14)
        }
        else if current == 34 || current == 39 {
            try change(current == 34 ? 6 : 7)
        }
        else if current == 35, state.continuation.visible == 0 {
            try change(9)
            repeat {
                cursor += 1
                try budget.consume()
            } while cursor < bytes.count && (byte(cursor) == 32 || byte(cursor) == 9)
            if lineEnd {
                try change(0)
            }
        }
        else if Self.isOperator(UInt8(truncatingIfNeeded: scalarValue(cursor))) {
            try change(10)
        }
    }
}
