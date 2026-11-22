import Foundation
import NateCore

struct SQLIndentationLine {
    private let points: [(end: Int, depth: Int)]
    private let closers: Set<Int>
    private let significant: [Int]

    /// 业务作用：SQL 同行目标共用实际关键字与圆括号索引，END 的后继词不重新开启块。
    /// 参数说明:
    /// - code: 字面和注释已遮蔽的原字节。
    /// - tokens: 本行完整 SQL 原生类别。
    /// - base: 本行在固定正文中的原字节起点。
    /// - significant: 已排序的非空白代码位置。
    /// - deadline: 所属结构输入共同截止。
    /// - permit: 当前输入仍允许准备的资格。
    /// 返回：有界的块与闭合位置索引；取消、失去资格或超时则拒绝整次准备。
    init(
        code: [UInt8],
        tokens: [SyntaxToken],
        base: Int,
        significant: [Int],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws {
        var points: [(end: Int, depth: Int)] = []
        var closers: Set<Int> = [], depth = 0, endSuffix = false
        for token in tokens {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("SQL 语言缩进已取消或超过共同截止。")
            }
            let lower = token.range.lower - base, upper = token.range.upper - base
            if token.lexicalStyle == "sql:10" {
                for index in lower..<upper {
                    if index & 255 == 0 {
                        try Task.checkCancellation()
                        guard permit(), ContinuousClock.now < deadline else {
                            throw NateError.message("SQL 圆括号缩进已取消或超过共同截止。")
                        }
                    }
                    if code[index] == 40 {
                        depth += 1
                        points.append((index + 1, depth))
                    }
                    else if code[index] == 41 {
                        depth = max(0, depth - 1)
                        closers.insert(index)
                        points.append((index + 1, depth))
                    }
                    if code[index] == 59 {
                        endSuffix = false
                    }
                }
                continue
            }
            guard token.lexicalStyle == "sql:5", upper - lower <= 9 else {
                continue
            }
            let word = String(
                decoding: code[lower..<upper].map { byte in
                    byte >= 65 && byte <= 90 ? byte + 32 : byte
                },
                as: UTF8.self
            )
            switch word {
            case "begin":
                depth += 1
                endSuffix = false
            case "case", "loop":
                if endSuffix {
                    endSuffix = false
                    continue
                }
                depth += 1
            case "then":
                depth = max(1, depth)
                endSuffix = false
            case "else", "exception":
                depth = max(1, depth)
                closers.insert(lower)
                endSuffix = false
            case "elsif", "when":
                closers.insert(lower)
                endSuffix = false
            case "end", "endif":
                depth = max(0, depth - 1)
                closers.insert(lower)
                endSuffix = true
            default:
                endSuffix = false
                continue
            }
            points.append((upper, depth))
        }
        self.points = points
        self.closers = closers
        self.significant = significant
    }

    /// 业务作用：SQL 回车只采用实际前缀与有代码资格的后继闭合，成对结构保持完整内外两行。
    /// 参数说明:
    /// - offset: 实际插入点相对当前行的原字节边界。
    /// - end: 替换范围的完整结束边界。
    /// - allowFollowing: 后继文本是否仍具有代码资格。
    /// 返回：增加、减少、成对展开或继承动作，不修改正文。
    func action(offset: Int, end: Int, allowFollowing: Bool) -> NewlineIndentationAction {
        var lower = 0, upper = points.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if points[middle].end <= offset {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        let depth = lower > 0 ? points[lower - 1].depth : 0
        var closes = false
        if allowFollowing {
            lower = 0
            upper = significant.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if significant[middle] < end {
                    lower = middle + 1
                }
                else {
                    upper = middle
                }
            }
            closes = lower < significant.count && closers.contains(significant[lower])
        }
        if depth > 0 {
            return closes ? .expandPair : .increase
        }
        return closes ? .decrease : .inherit
    }
}
