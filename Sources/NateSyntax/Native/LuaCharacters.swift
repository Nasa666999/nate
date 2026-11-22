import Foundation

extension LuaLexing {
    /// 业务作用：前瞻只访问已经确认的原字节，范围外零哨兵不授予真实换行资格。
    /// 参数说明:
    /// - index: 当前分析范围中的相对位置。
    /// 返回：范围内的原字节；范围外为零。
    func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < bytes.count ? bytes[index] : 0
    }

    /// 业务作用：扫描推进保持完整 UTF-8 标量边界，不把名称尾字节当成新标点。
    /// 参数说明:
    /// - index: 已经确认的标量首字节或范围末尾。
    /// 返回：真实标量宽度；范围末尾为零。
    func width(_ index: Int) -> Int {
        guard index >= 0, index < bytes.count else {
            return 0
        }
        let first = bytes[index]
        return first < 128 ? 1 : (first < 224 ? 2 : (first < 240 ? 3 : 4))
    }

    /// 业务作用：名称、标签及未闭合字符串在确认边界后统一着色，保留整段重新分类的资格。
    /// 参数说明:
    /// - mode: 片段结束后的新类别。
    /// 返回：已消费片段取得当前类别；预算不足时拒绝整份结果。
    mutating func change(_ mode: Int) throws {
        let end = min(cursor, bytes.count)
        for index in segment..<end {
            try budget.consume()
            classes[index] = UInt8(state.mode)
        }
        segment = end
        state.mode = mode
    }

    /// 业务作用：原始字节级前移同时保留真实物理行首，跳过的引号或续行不丢失行位置。
    /// 参数说明:
    /// - count: 已经由语法确认要消费的原字节数量。
    /// 返回：游标推进到对应边界；每个实际字节计入共同预算。
    mutating func advance(_ count: Int) throws {
        let end = min(bytes.count, cursor + count)
        while cursor < end {
            try budget.consume()
            let current = bytes[cursor]
            state.continuation.atLineStart = current == 10 || current == 13 && byte(cursor + 1) != 10
            cursor += 1
        }
    }

    /// 业务作用：复合名称按原生原字节量推进完整标量，跨物理范围的剩余分类只沿同源检查点继续。
    /// 参数说明:
    /// - count: 名称分类要求的原字节推进量。
    /// - style: 推进片段所属的原生类别。
    /// 返回：实际标量边界已经推进；尚无后继原文时保存最多两个有界片段，不读取未确认字节。
    mutating func advanceProjected(_ count: Int, style: Int) throws {
        guard count > 0 else {
            return
        }
        if !state.continuation.pending.isEmpty {
            state.continuation.pending.append(
                LuaPendingSpan(
                    bytes: count,
                    style: style
                )
            )
            return
        }
        let target = cursor + count
        while cursor < target, cursor < bytes.count {
            try advance(width(cursor))
        }
        if cursor < target, !documentEnd {
            state.continuation.pending.append(
                LuaPendingSpan(
                    bytes: target - cursor,
                    style: style
                )
            )
        }
    }

    /// 业务作用：前一物理范围未结束的名称推进先于后继代码解释，Unicode 标量尾部不形成新的语法开端。
    /// 参数说明: 无。
    /// 返回：当前范围内的延续片段已完整着色，未消费部分仍绑定原检查点；文件末尾停止剩余推进。
    mutating func drainPending() throws {
        while let first = state.continuation.pending.first, cursor < bytes.count {
            try change(first.style)
            let target = cursor + first.bytes
            while cursor < target, cursor < bytes.count {
                try advance(width(cursor))
            }
            if cursor < target {
                state.continuation.pending[0].bytes = target - cursor
            }
            else {
                state.continuation.pending.removeFirst()
            }
            try change(0)
            if cursor < target {
                break
            }
        }
        if documentEnd, cursor == bytes.count {
            state.continuation.pending.removeAll()
        }
    }

    /// 业务作用：Lua 名称按原生规则接纳 ASCII 字母、下划线和完整非 ASCII 原字节。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：名称首字节集合成员为真。
    static func wordStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte >= 128
    }

    /// 业务作用：名称后继允许十进制数字，句点与冒号由复合名称规则单独处理。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：名称内部原字节集合成员为真。
    static func word(_ byte: UInt8) -> Bool {
        wordStart(byte) || digit(byte)
    }

    /// 业务作用：数字开端只采用 ASCII 十进制字符，不进行区域或数值求值。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：0–9 为真。
    static func digit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    /// 业务作用：空白转义采用原生 ASCII 空白集合，Unicode 显示换行不代替物理行。
    /// 参数说明:
    /// - byte: 当前原字节。
    /// 返回：ASCII 空格或 9–13 为真。
    static func space(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    /// 业务作用：长字面定界符最多接纳 254 个等号，超长候选退回普通操作符。
    /// 参数说明:
    /// - start: 方括号开端所在的相对原字节。
    /// 返回：包含末端方括号位置的分隔量；不完整或超量时为零。
    mutating func delimiter(at start: Int) throws -> Int {
        var amount = 1
        while byte(start + amount) == 61, amount <= 254 {
            try budget.consume()
            amount += 1
        }
        return byte(start + amount) == byte(start) ? amount : 0
    }

    /// 业务作用：只有实际 LF、独立 CR 和真正文件末尾提供行结束证据。
    /// 参数说明: 无。
    /// 返回：当前字节确实结束物理行或完整文件时为真。
    var lineEnd: Bool {
        byte(cursor) == 10 || byte(cursor) == 13 && byte(cursor + 1) != 10
            || documentEnd && cursor == bytes.count
    }
}
