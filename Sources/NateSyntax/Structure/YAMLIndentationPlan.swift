import Foundation
import NateCore

enum YAMLIndentationPlan {
    /// 业务作用：按真实物理行传播 YAML 引用、块标量与流容器，为所有换行目标准备一次结构事务。
    /// 参数说明:
    /// - snapshot: 全部选区共同持有的固定正文。
    /// - ranges: 已复验原字节边界的完整目标。
    /// - deadline: 词法、缩进及最终提交共用的截止。
    /// - permit: 当前编辑动作继续准备的资格。
    /// 返回：完整的逐目标结构动作；容量、取消或范围不足时整体失败。
    static func actions(
        snapshot: DocumentSnapshot,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：让行间传播与全部目标共享输入事务的取消和截止。
        /// 参数说明: 无。
        /// 返回：当前准备仍可进行时通过，资格或期限失效时整体停止。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("YAML 语言缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var targetsByLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            targetsByLine[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = targetsByLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("YAML 语言缩进的前置传播超过一百万行。")
        }
        var remainingSource = 64 * 1024 * 1024
        var remainingPrefixes = 1024 * 1024
        var prefixes = [0: ""]
        var state = YAMLIndentationState()
        var result: [ByteRange: NewlineIndentationAction] = [:]
        for line in 0...last {
            try check()
            let complete = text.lineRange(line)
            // 先检查物理行和全部前置原字节，避免已经处理的光标独自提交。
            guard complete.count <= 1024 * 1024, complete.count <= remainingSource else {
                throw NateError.message("YAML 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            remainingSource -= complete.count
            let row = text.lineRange(line, includeEnding: false)
            let bytes = Array(text.bytes(in: row))
            let targets = targetsByLine[line] ?? []
            var scanner = try YAMLIndentationLine(bytes: bytes, state: &state, check: check)
            let suffixes = try following(bytes, row: row, targets: targets, check: check)
            for target in targets.sorted(by: { $0.lower < $1.lower }) {
                try check()
                let offset = min(target.lower - row.lower, bytes.count)
                try scanner.scan(through: offset, state: &state, check: check)
                let next = suffixes[target].map { bytes[$0] }
                switch scanner.action(at: offset, following: next, state: state) {
                case .inherit:
                    result[target] = .inherit
                case .increase:
                    result[target] = .increase
                case .expandPair:
                    result[target] = .expandPair
                case .align(let column, let levels):
                    let prefix: String
                    if let cached = prefixes[column] {
                        prefix = cached
                    }
                    else {
                        // 同一空白前缀只分配一次，避免长缩进乘以多选区数量。
                        guard column <= remainingPrefixes else {
                            throw NateError.message("YAML 对齐需要的完整原始前缀超过 1 MiB。")
                        }
                        remainingPrefixes -= column
                        prefix = String(repeating: " ", count: column)
                        prefixes[column] = prefix
                    }
                    result[target] = .align(prefix: prefix, levels: levels)
                }
            }
            try scanner.scan(through: bytes.count, state: &state, check: check)
        }
        try check()
        return result
    }

    /// 业务作用：按替换终点寻找同一物理行留下的后继，连续空白只扫描一次。
    /// 参数说明:
    /// - bytes: 不含物理换行的原行内容。
    /// - row: 该行在正文中的真实字节位置。
    /// - targets: 在本行开始的全部替换范围。
    /// - check: 当前事务的继续资格。
    /// 返回：尚有同一行后继的目标及其行内位置；跨行或行尾目标无后继。
    private static func following(
        _ bytes: [UInt8],
        row: ByteRange,
        targets: [ByteRange],
        check: () throws -> Void
    ) throws -> [ByteRange: Int] {
        var cursor = 0
        var offsets: [ByteRange: Int] = [:]
        for target in targets.sorted(by: { $0.upper < $1.upper }) {
            try check()
            guard target.upper < row.upper else {
                break
            }
            cursor = max(cursor, target.upper - row.lower)
            while cursor < bytes.count, YAMLIndentationLine.isSeparation(bytes[cursor]) {
                if cursor & 255 == 0 {
                    try check()
                }
                cursor += 1
            }
            if cursor < bytes.count {
                offsets[target] = cursor
            }
        }
        return offsets
    }
}
