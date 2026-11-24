import NateCore

enum RustNewlineDelimiters {
    /// 业务作用：沿 Rust 真实代码界定符配对决定调用、元组、数组和代码块的换行缩进。
    /// 参数说明:
    /// - opener: 已经剔除注释和字面的前置代码字节。
    /// 返回：对应的同类闭合字节，其它代码或缺少开端时为空。
    static func closer(for opener: UInt8?) -> UInt8? {
        switch opener {
        case 40: 41
        case 91: 93
        case 123: 125
        default: nil
        }
    }

    /// 业务作用：在真实闭合之前减少一个 Rust 逻辑缩进层级。
    /// 参数说明:
    /// - byte: 插入范围之后同一物理行的代码字节。
    /// 返回：圆、方或花括号闭合时为真。
    static func isCloser(_ byte: UInt8?) -> Bool {
        byte == 41 || byte == 93 || byte == 125
    }

    /// 业务作用：仅在两端确属同一 Rust 代码界定范围时展开内外行，多目标不借用另一组闭合符。
    /// 参数说明:
    /// - code: 当前物理行已遮蔽注释和字面的等长原字节。
    /// - source: 当前物理行未遮蔽的原字节，用于确认尾随空白。
    /// - before: 换行范围之前的最近有效代码位置。
    /// - end: 当前替换目标沿本物理行的结束位置。
    /// - allowFollowing: 插入点在行注释外时才可采用右侧代码。
    /// - deadline: 全部输入目标的共同截止。
    /// - permit: 维持本轮输入准备权的检查。
    /// 返回：继承、增加、减少或展开已确认的同类范围；取消、过量嵌套或超时不发布部分动作。
    static func action(
        in code: [UInt8],
        source: [UInt8],
        before: Int?,
        end: Int,
        allowFollowing: Bool,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> NewlineIndentationAction {
        let hasSuffix = allowFollowing && code.indices.contains(end)
        guard let before, let closer = closer(for: code[before]) else {
            return hasSuffix && isCloser(code[end]) ? .decrease : .inherit
        }
        guard hasSuffix, end > before else {
            return .increase
        }
        var following = end
        // 只可越过确实存在的空格或 Tab，不能把遮蔽成空格的注释移进闭合行。
        while following < source.count, source[following] == 32 || source[following] == 9 {
            if following & 255 == 0 {
                try check(deadline: deadline, permit: permit)
            }
            following += 1
        }
        guard code.indices.contains(following), code[following] == closer else {
            return .increase
        }
        var nested: [UInt8] = []
        for offset in (before + 1)..<end {
            if offset & 255 == 0 {
                try check(deadline: deadline, permit: permit)
            }
            let byte = code[offset]
            if let expected = Self.closer(for: byte) {
                guard nested.count < 65_536 else {
                    throw NateError.message("Rust 换行的配对嵌套超过 65536 层。")
                }
                nested.append(expected)
            }
            else if isCloser(byte) {
                // 一旦所选范围已经闭合原开端或与内部开端交叉，后继同类字节没有展开该范围的资格。
                guard nested.last == byte else {
                    return .increase
                }
                nested.removeLast()
            }
        }
        return nested.isEmpty ? .expandPair : .increase
    }

    /// 业务作用：结构边界和嵌套读取共享整批换行的取消与时间限制。
    /// 参数说明:
    /// - deadline: 本次完整输入的共同截止。
    /// - permit: 当前输入仍有权准备结果的同步检查。
    /// 返回：仍可准备时正常返回，否则抛错并撤销本次整批动作。
    private static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("Rust 换行的配对分析已失效或超过截止。")
        }
    }
}
