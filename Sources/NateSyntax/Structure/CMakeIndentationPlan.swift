import Foundation
import NateCore

enum CMakeIndentationPlan {
    private enum Context {
        case opaque
        case code(String?)
    }
    /// 业务作用：CMake 全部光标共享同源命令与字面传播，只为完整块命令和有资格的后继闭合准备换行。
    /// 参数说明:
    /// - snapshot: 本次输入固定的完整正文。
    /// - ranges: 全部真实替换范围。
    /// - deadline: 本次准备与最终提交共用的截止。
    /// - permit: 本次输入继续准备的资格。
    /// 返回：全部目标的不可变结构动作；范围、容量或资格不足时整份抛错。
    static func actions(
        snapshot: DocumentSnapshot,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check(deadline: deadline, permit: permit)
            byLine[snapshot.text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("CMake 语言缩进的前置传播超过一百万行。")
        }
        var state = CMakeIndentationState()
        var output: [ByteRange: NewlineIndentationAction] = [:]
        var consumed = 0
        for line in 0...last {
            try check(deadline: deadline, permit: permit)
            let row = snapshot.text.lineRange(line)
            // 完整容量先于原文复制确认，超量不能准备部分光标或失去先前字面状态后继续猜测。
            guard row.count <= 1_048_576, row.count <= 67_108_864 - consumed else {
                throw NateError.message("CMake 语言缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            consumed += row.count
            let bytes = Array(snapshot.text.text(in: row).utf8)
            let targets = (byLine[line] ?? []).sorted {
                $0.lower < $1.lower
            }
            var prefix: [ByteRange: Context] = [:]
            var closers: [Int: String] = [:]
            var next = 0
            var completed: String?
            state.beginLine()
            for index in 0...bytes.count {
                if index & 255 == 0 {
                    try check(deadline: deadline, permit: permit)
                }
                while next < targets.count && targets[next].lower - row.lower == index {
                    let opaque = state.quote || state.bracket != nil || state.escaped || state.depth > 0
                    // 注释只遮蔽后继证据，完整块命令后的行尾说明仍可继承该命令已经建立的资格。
                    prefix[targets[next]] = opaque ? .opaque : .code(completed)
                    next += 1
                }
                if index == bytes.count {
                    break
                }
                if line == 0 && index < 3 && bytes.starts(with: [239, 187, 191]) {
                    continue
                }
                let event = try state.consume(bytes, at: index, deadline: deadline, permit: permit)
                if let name = event.completed {
                    completed = name
                }
                if let started = event.started, CMakeIndentationState.closers.contains(started.name) {
                    guard closers.count < 65_536 else {
                        throw NateError.message("CMake 语言缩进的同行闭合命令超过容量。")
                    }
                    closers[started.lower] = started.name
                }
            }
            var following: [Int] = []
            if !targets.isEmpty {
                following = [Int](repeating: bytes.count, count: bytes.count + 1)
                for index in bytes.indices.reversed() {
                    if index & 255 == 0 {
                        try check(deadline: deadline, permit: permit)
                    }
                    following[index] = bytes[index] == 32 || bytes[index] == 9 ? following[index + 1] : index
                }
            }
            for target in targets {
                try check(deadline: deadline, permit: permit)
                guard let captured = prefix[target] else {
                    throw NateError.message("CMake 语言缩进缺少完整插入边界。")
                }
                guard case .code(let completed) = captured else {
                    output[target] = .inherit
                    continue
                }
                let end = target.upper - row.lower
                let closing = end >= 0 && end < bytes.count ? closers[following[end]] : nil
                if let completed, CMakeIndentationState.openers.contains(completed) {
                    output[target] =
                        CMakeIndentationState.matches(completed, closing: closing) ? .expandPair : .increase
                }
                else {
                    output[target] = closing == nil ? .inherit : .decrease
                }
            }
        }
        try check(deadline: deadline, permit: permit)
        return output
    }

    /// 业务作用：CMake 前行传播、定界符及所有目标采用同一执行资格，取消不能留下部分动作。
    /// 参数说明:
    /// - deadline: 本次输入的共同截止。
    /// - permit: 当前输入继续准备的资格。
    /// 返回：仍具备完整资格时继续；取消或超时则抛错。
    static func check(deadline: ContinuousClock.Instant, permit: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard permit(), ContinuousClock.now < deadline else {
            throw NateError.message("CMake 语言缩进已取消或超过共同截止，正文与选择保持原状。")
        }
    }
}
