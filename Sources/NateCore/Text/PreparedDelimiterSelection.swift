import Foundation

public struct PreparedDelimiterSelection: Sendable {
    public let selection: TextSelection?

    /// 业务作用：在固定原文中寻找点击位置所属的分隔符对，按原始标量流处理而不复制全文。
    /// 参数说明:
    /// - text: 本次选择固定的不可变正文树。
    /// - position: 完整 UTF-8 标量边界的点击或光标位置。
    /// - settings: 两端字符与当前行或全文范围。
    /// - maximumBytes: 完整扫描范围允许的最大原字节数，默认 64 MiB。
    /// - maximumDepth: 不同分隔符允许的最大未闭合层数，默认 262144。
    /// - permit: 外部取消或来源失权时返回假。
    /// 返回：完整成对时保留内侧选择方向；未成对为空，取消、五秒或容量不足时整体失败。
    public init(
        text: PieceTree,
        position: Int,
        settings: DelimiterSelectionSettings,
        maximumBytes: Int = 67_108_864,
        maximumDepth: Int = 262_144,
        permit: @Sendable () -> Bool = {
            true
        }
    ) throws {
        guard text.isBoundary(position), maximumBytes > 0, maximumDepth > 0,
            let opening = settings.opening.unicodeScalars.first?.value,
            let closing = settings.closing.unicodeScalars.first?.value
        else {
            throw NateError.invalidRange
        }
        let scope =
            settings.entireDocument
            ? ByteRange(0, text.byteCount) : text.lineRange(text.lineNumber(at: position))
        // 不能把被预算截断的前缀冒充完整范围，超长行与全文均在读取前拒绝。
        guard scope.count <= maximumBytes else {
            throw NateError.message("分隔符选择范围超过 \(maximumBytes) 字节，原选区保留。")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let width = settings.opening.utf8.count
        var stack: [Int] = []
        var left: Int?
        var right: Int?
        var previous: UInt32?
        var offset = scope.lower
        var steps = 0
        var found: TextSelection?
        do {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            try text.slicing(scope).forEachChunk(maximumBytes: 65_536) {
                chunk in
                // 每块都是完整 UTF-8，保留前一标量以跨块识别双引号之前的反斜杠。
                let characters = String(decoding: chunk.bytes(), as: UTF8.self).unicodeScalars
                for scalar in characters {
                    if steps.isMultiple(of: 4096) {
                        try Task.checkCancellation()
                        guard permit(), ContinuousClock.now < deadline else {
                            throw CancellationError()
                        }
                    }
                    steps += 1
                    let value = scalar.value
                    if opening == closing {
                        if value == opening, opening != 34 || previous != 92 {
                            if offset <= position {
                                left = offset
                            }
                            if offset >= position, right == nil {
                                right = offset
                            }
                            if let left, let right {
                                throw DelimiterSelectionStop.found(
                                    TextSelection(anchor: left + width, head: right)
                                )
                            }
                        }
                    }
                    else if value == opening {
                        guard stack.count < maximumDepth else {
                            throw NateError.message("分隔符嵌套超过 \(maximumDepth) 层，原选区保留。")
                        }
                        stack.append(offset)
                    }
                    else if value == closing, let start = stack.popLast(),
                        start <= position, offset >= position
                    {
                        // 首个包围点击的闭合对就是最内层；不把语言字符串或注释当作排除规则。
                        throw DelimiterSelectionStop.found(
                            TextSelection(anchor: start + width, head: offset)
                        )
                    }
                    previous = value
                    offset += scalar.utf8.count
                }
            }
        }
        catch DelimiterSelectionStop.found(let selection) {
            found = selection
        }
        catch is CancellationError {
            try Task.checkCancellation()
            throw NateError.message("分隔符选择已取消或超过五秒预算，原选区保留。")
        }
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("分隔符选择已取消或超过五秒预算，原选区保留。")
        }
        selection = found
    }
}

private enum DelimiterSelectionStop: Error {
    case found(TextSelection)
}
