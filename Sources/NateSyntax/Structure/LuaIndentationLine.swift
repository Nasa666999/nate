import Foundation
import NateCore

struct LuaIndentationLine {
    private let points: [(end: Int, opens: Bool)]
    private let closers: Set<Int>
    private let significant: [Int]
    private let code: [UInt8]

    /// 业务作用：按明确词法身份建立同行 Lua 代码块索引，多光标共享前缀结果而不重复扫描整行。
    /// 参数说明:
    /// - code: 已遮蔽字面和注释的原字节。
    /// - tokens: 同源完整词元。
    /// - base: 当前逻辑行的原字节起点。
    /// - significant: 当前行有序非空白位置。
    /// - deadline: 本次输入共同截止。
    /// - permit: 本次输入继续准备的资格。
    /// 返回：函数、条件、循环和分支的有界前缀索引；失去资格时拒绝整次准备。
    init(
        code: [UInt8],
        tokens: [SyntaxToken],
        base: Int,
        significant: [Int],
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws {
        var stack: [Bool] = []
        var active = 0
        var points: [(end: Int, opens: Bool)] = []
        var closers: Set<Int> = []
        for token in tokens where token.lexicalStyle == "lua:5" {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Lua 语言缩进已取消或超过共同截止。")
            }
            let lower = token.range.lower - base, upper = token.range.upper - base
            let word = String(decoding: code[lower..<upper], as: UTF8.self)
            switch word {
            case "if":
                stack.append(false)
            case "function", "do", "repeat":
                stack.append(true)
                active += 1
            case "then", "else", "elseif":
                if let previous = stack.popLast(), previous {
                    active -= 1
                }
                let opens = word != "elseif"
                stack.append(opens)
                if opens {
                    active += 1
                }
                if word != "then" {
                    closers.insert(lower)
                }
            case "end", "until":
                if let previous = stack.popLast(), previous {
                    active -= 1
                }
                closers.insert(lower)
            default:
                break
            }
            points.append((upper, active > 0))
        }
        self.points = points
        self.closers = closers
        self.code = code
        self.significant = significant
    }

    /// 业务作用：真实回车只按插入点之前的完整代码块增加缩进，后继明确闭合关键字可形成内外两行。
    /// 参数说明:
    /// - offset: 插入点相对当前行的边界。
    /// - end: 已确认替换范围结束的相对边界。
    /// - last: 插入点前最后一个有效代码字节。
    /// - allowFollowing: 后继仍位于当前行代码区，行注释不能授予闭合资格。
    /// 返回：增加、减少、成对展开或继承动作，不直接改变正文。
    func action(
        offset: Int,
        end: Int,
        last: UInt8?,
        allowFollowing: Bool
    ) -> NewlineIndentationAction {
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
        let opens = lower > 0 && points[lower - 1].opens
        var next: Int?
        if allowFollowing, end >= 0, end <= code.count {
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
            if lower < significant.count {
                next = significant[lower]
            }
        }
        if last == 123 {
            return next.map {
                code[$0] == 125
            } == true ? .expandPair : .increase
        }
        let closes =
            next.map {
                code[$0] == 125 || closers.contains($0)
            } == true
        if opens {
            return closes ? .expandPair : .increase
        }
        return closes ? .decrease : .inherit
    }
}
