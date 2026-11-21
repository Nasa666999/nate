import Foundation
import NateCore

enum TeXFolding {
    /// 业务作用：TeX 成对命令、章节、注释组与明确标记形成真实行层级，原文不被执行。
    /// 参数说明:
    /// - snapshot: 当前完整不可变正文。
    /// - deadline: 本次完整转换的共同截止。
    /// 返回：至多 65536 个含从属行的范围；容量、取消或时间不足时整体拒绝。
    static func regions(snapshot: DocumentSnapshot, deadline: ContinuousClock.Instant) throws -> [FoldRegion]
    {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("TeX 折叠超过正文或行数预算。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        var comments = Array(repeating: false, count: tree.lineCount)
        for line in 0..<tree.lineCount {
            let range = tree.lineRange(line)
            guard range.count <= 1_048_576 else {
                throw NateError.message("TeX 折叠涉及超过 1 MiB 的物理行。")
            }
            var position = range.lower
            while position < range.upper - 1 {
                try budget.consume()
                let byte = tree.byte(at: position)
                if byte == 37 {
                    comments[line] = true
                    break
                }
                if byte != 32 {
                    break
                }
                position += 1
            }
        }
        var levels = Array(repeating: 1024, count: tree.lineCount)
        var previous = 1024
        var current = 1024
        var visible = 0
        for line in 0..<tree.lineCount {
            let range = tree.lineRange(line)
            for (offset, byte) in tree.bytes(in: range).enumerated() {
                try budget.consume()
                let position = range.lower + offset
                let next = tree.byte(at: position + 1) ?? 0
                let ending = byte == 10 || byte == 13 && next != 10
                if byte == 92 {
                    let name = try command(at: position, tree: tree, budget: &budget)
                    current += paired(name) + unpaired(name)
                }
                if current > 1024, byte == 13 || byte == 10, next == 92 {
                    current -= unpaired(try command(at: position + 1, tree: tree, budget: &budget))
                }
                if byte == 37 {
                    if try matches("%%--{{", at: position, tree: tree, budget: &budget) {
                        current += 1
                    }
                    if try matches("%%}}--", at: position, tree: tree, budget: &budget) {
                        current -= 1
                    }
                }
                if byte == 92, next == 91 {
                    current += 1
                }
                if byte == 92, next == 93 {
                    current -= 1
                }
                if ending, comments[line] {
                    let before = line > 0 && comments[line - 1]
                    let after = line + 1 < comments.count && comments[line + 1]
                    if !before && after {
                        current += 1
                    }
                    else if before && !after {
                        current -= 1
                    }
                }
                if ending {
                    levels[line] = previous | (current > previous && visible > 0 ? 8192 : 0)
                    previous = current
                    visible = 0
                    if line + 1 < levels.count {
                        levels[line + 1] = previous
                    }
                }
                if !(byte == 32 || byte >= 9 && byte <= 13) {
                    visible += 1
                }
            }
        }
        var ends = Array(repeating: levels.count - 1, count: levels.count)
        var stack: [Int] = []
        for line in levels.indices {
            try budget.consume()
            while let parent = stack.last, (levels[line] & 4095) <= (levels[parent] & 4095) {
                ends[parent] = line - 1
                stack.removeLast()
            }
            if levels[line] & 8192 != 0 {
                stack.append(line)
            }
        }
        var output: [FoldRegion] = []
        for line in levels.indices where levels[line] & 8192 != 0 && ends[line] > line {
            try budget.consume()
            guard output.count < 65_536 else {
                throw NateError.message("TeX 折叠超过 65536 个范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(line).lower, tree.lineRange(ends[line]).upper),
                    startLine: line,
                    endLine: ends[line],
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
