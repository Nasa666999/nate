import Foundation

extension PowerShellLexing {
    /// 业务作用：PowerShell 多行字面状态按真实原文传播，闭合字符后的代码在同一位置继续识别。
    /// 参数说明: 无。
    /// 返回：完整原字节类别与行后状态；预算不足时由调用者丢弃全部局部结果。
    mutating func scan() throws {
        while cursor < bytes.count {
            try budget.consume()
            let current = byte(cursor)
            switch state.mode {
            case 1:
                if current == 10 || current == 13 {
                    try change(0)
                }
            case 13:
                if lineStart {
                    while cursor < bytes.count, byte(cursor) == 32 || byte(cursor) == 9 {
                        try budget.consume()
                        cursor += 1
                    }
                    if byte(cursor) == 46, Self.word(byte(cursor + 1)) {
                        try change(16)
                    }
                }
                if byte(cursor) == 62, byte(cursor - 1) == 35 {
                    cursor += 1
                    try change(0)
                    continue
                }
            case 16:
                if !Self.word(current) {
                    classify(documentation: true)
                    try change(13)
                }
            case 2:
                if current == 34 {
                    cursor += 1
                    try change(0)
                    continue
                }
                if current == 96 {
                    cursor += 1
                    cursor += width(cursor)
                    continue
                }
            case 3:
                if current == 39 {
                    cursor += 1
                    try change(0)
                    continue
                }
            case 14, 15:
                if lineStart, current == (state.mode == 14 ? 34 : 39), byte(cursor + 1) == 64 {
                    cursor += 2
                    try change(0)
                    continue
                }
            case 4:
                if !Self.numeric(previous: byte(cursor - 1), current: current, next: byte(cursor + 1)) {
                    if current == 10 || current == 13 || current == 32 || current == 9
                        || Self.isOperator(current)
                    {
                        try change(0)
                    }
                    else {
                        state.mode = 7
                    }
                }
            case 5:
                if !Self.word(current) {
                    try change(0)
                }
            case 6:
                if !Self.isOperator(current) {
                    try change(0)
                }
            case 7:
                if !Self.word(current) {
                    classify(documentation: false)
                    try change(0)
                }
            default: break
            }
            if state.mode == 0 {
                try enter()
            }
            cursor += width(cursor)
        }
        if documentEnd {
            // 文件末尾是词边界证据，显示分段末尾则不能提前结束跨行字面状态。
            if state.mode == 7 || state.mode == 16 {
                let documentation = state.mode == 16
                classify(documentation: documentation)
                try change(documentation ? 13 : 0)
            }
            else if [1, 4, 5, 6].contains(state.mode) {
                try change(0)
            }
        }
        try change(state.mode)
    }

    /// 业务作用：代码区按固定优先级进入注释、字面、变量、数字、运算符或名称。
    /// 参数说明: 无。
    /// 返回：当前类别开始于真实原字节；反引号跳过完整后继标量，避免把 UTF-8 尾字节当新名称。
    private mutating func enter() throws {
        let current = byte(cursor), next = byte(cursor + 1)
        let mode: Int
        if current == 35 {
            mode = 1
        }
        else if current == 60, next == 35 {
            mode = 13
        }
        else if current == 34 || current == 39 {
            mode = current == 34 ? 2 : 3
        }
        else if current == 64, next == 34 || next == 39 {
            mode = next == 34 ? 14 : 15
        }
        else if current == 36 {
            mode = 5
        }
        else if (48...57).contains(current)
            || current == 46 && byte(cursor - 1) != 46 && (48...57).contains(next)
        {
            mode = 4
        }
        else if Self.isOperator(current) {
            mode = 6
        }
        else if Self.word(current) {
            mode = 7
        }
        else {
            if current == 96 {
                cursor += 1
            }
            return
        }
        try change(mode)
    }
}
