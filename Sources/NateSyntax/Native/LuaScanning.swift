import Foundation

extension LuaLexing {
    /// 业务作用：普通字符串、长定界符及文档注释分别传播，所有前瞻和重新着色共用动作预算。
    /// 参数说明:
    /// - finalize: 完整分析范围结束时发布最后片段；单引号续行聚合期间保留跨行重分类资格。
    /// 返回：局部类别和延续状态完整更新；取消或超量时不向外部发布部分状态。
    mutating func scan(finalize: Bool = true) throws {
        if absoluteStart == 0, cursor == 0, byte(0) == 35, byte(1) == 33 {
            state.mode = 2
        }
        while cursor < bytes.count || documentEnd && cursor == bytes.count {
            try budget.consume()
            if !state.continuation.pending.isEmpty {
                try drainPending()
                if cursor >= bytes.count, !documentEnd {
                    break
                }
            }
            if state.continuation.atLineStart, state.mode == 6 {
                try change(6)
            }
            if (state.mode == 6 || state.mode == 7), byte(cursor) == 92,
                byte(cursor + 1) == 10 || byte(cursor + 1) == 13
            {
                try advance(1)
                if byte(cursor) == 13, byte(cursor + 1) == 10 {
                    try advance(1)
                }
                try advance(1)
                continue
            }
            if state.mode == 10 {
                if byte(cursor) == 58, byte(cursor - 1) == 58 {
                    try label()
                }
                try change(0)
            }
            else if state.mode == 4 {
                let current = byte(cursor)
                let numeric =
                    Self.digit(current)
                    || [
                        46, 45, 43, 97, 98, 99, 100, 101, 102, 112,
                        65, 66, 67, 68, 69, 70, 80,
                    ].contains(current)
                if !numeric
                    || (current == 45 || current == 43)
                        && ![101, 69, 112, 80].contains(byte(cursor - 1))
                {
                    try change(0)
                }
            }
            else if [2, 3, 9].contains(state.mode), lineEnd {
                try advance(width(cursor))
                try change(0)
            }
            else if state.mode == 6 || state.mode == 7 {
                if state.continuation.stringWhitespace, !Self.space(byte(cursor)) {
                    state.continuation.stringWhitespace = false
                }
                let quote: UInt8 = state.mode == 6 ? 34 : 39
                if byte(cursor) == 92 {
                    if [34, 39, 92].contains(byte(cursor + 1)) {
                        try advance(1)
                    }
                    else if byte(cursor + 1) == 122 {
                        try advance(1)
                        state.continuation.stringWhitespace = true
                    }
                }
                else if byte(cursor) == quote {
                    try advance(1)
                    try change(0)
                }
                else if !state.continuation.stringWhitespace, lineEnd {
                    state.mode = 12
                    try advance(width(cursor))
                    try change(0)
                }
            }
            else if byte(cursor) == 93, state.mode == 8 || state.mode == 1 {
                let separator = try delimiter(at: cursor)
                if separator == state.continuation.separator {
                    try advance(separator + 1)
                    try change(0)
                }
            }
            if cursor >= bytes.count, !documentEnd {
                break
            }
            if state.mode == 0 {
                let current = byte(cursor)
                if Self.digit(current) || current == 46 && Self.digit(byte(cursor + 1)) {
                    try change(4)
                    if current == 48, byte(cursor + 1) == 120 || byte(cursor + 1) == 88 {
                        try advance(1)
                    }
                }
                else if Self.wordStart(current) {
                    try change(11)
                    state.continuation.documentComment = false
                    try identifier()
                    continue
                }
                else if current == 34 || current == 39 {
                    try change(current == 34 ? 6 : 7)
                    state.continuation.stringWhitespace = false
                }
                else if current == 91 {
                    let separator = try delimiter(at: cursor)
                    state.continuation.separator = separator
                    try change(separator == 0 ? 10 : 8)
                    if separator > 0 {
                        try advance(separator)
                    }
                }
                else if current == 45, byte(cursor + 1) == 45 {
                    try change(state.continuation.documentComment ? 3 : 2)
                    if byte(cursor + 2) == 91 {
                        try advance(2)
                        let separator = try delimiter(at: cursor)
                        state.continuation.separator = separator
                        if separator > 0 {
                            state.mode = 1
                            try advance(separator)
                        }
                    }
                    else if byte(cursor + 2) == 45 {
                        try change(3)
                        state.continuation.documentComment = true
                    }
                    else {
                        try advance(1)
                    }
                }
                else if state.continuation.atLineStart, current == 36 {
                    try change(9)
                }
                else if [
                    42, 47, 45, 43, 40, 41, 61, 123, 125, 126, 91, 93,
                    59, 60, 62, 44, 46, 94, 37, 58, 35, 38, 124,
                ].contains(current) {
                    try change(10)
                }
                if state.mode != 0, state.mode != 3 {
                    state.continuation.documentComment = false
                }
            }
            guard cursor < bytes.count else {
                break
            }
            try advance(width(cursor))
        }
        if finalize {
            try change(state.mode)
        }
    }
}
