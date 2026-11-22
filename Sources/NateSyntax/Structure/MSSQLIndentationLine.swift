import Foundation
import NateCore

struct MSSQLIndentationLine {
    private let points: [(end: Int, depth: Int, ended: Bool)]
    private let closers: Set<Int>
    private let significant: [Int]
    private let code: [UInt8]
    private let conditionEnd: Int?
    let isCondition: Bool

    /// 业务作用：T-SQL 同行目标共用已确认的块与条件前缀，真实 EOF 名称按当前类型优先资格确认。
    /// 参数说明:
    /// - code: 字面与注释已遮蔽的原字节。
    /// - tokens: 当前行完整词法身份。
    /// - base: 当前行的原字节起点。
    /// - initial: 当前行之前的类型优先上下文。
    /// - significant: 已排序的非空白字节位置。
    /// - rules: 当前完整 T-SQL 名称和样式。
    /// - deadline: 所属输入共同截止。
    /// - permit: 当前输入仍可准备的资格。
    /// 返回：有界块与条件索引，取消或来源不足时拒绝整次准备。
    init(
        code: [UInt8],
        tokens: [SyntaxToken],
        base: Int,
        initial: MSSQLLexicalState,
        significant: [Int],
        rules: MSSQLRules,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws {
        var points: [(end: Int, depth: Int, ended: Bool)] = []
        var closers: Set<Int> = [], depth = 0
        var conditionEnd: Int?
        for (index, token) in tokens.enumerated() {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("T-SQL 语言缩进已取消或超过共同截止。")
            }
            let lower = token.range.lower - base, upper = token.range.upper - base
            guard upper - lower <= 5 else {
                continue
            }
            if token.lexicalStyle != "mssql:9" {
                guard token.lexicalStyle == "mssql:6" else {
                    continue
                }
                let preceding = index > 0 ? tokens[index - 1].lexicalStyle : ""
                let prefersType =
                    index == 0 ? initial.mode == 15 : ["mssql:15", "mssql:8", "mssql:16"].contains(preceding)
                guard rules.identifier(code[lower..<upper], prefersType: prefersType, global: false) == 9
                else {
                    continue
                }
            }
            let word = String(
                decoding: code[lower..<upper].map { byte in
                    byte >= 65 && byte <= 90 ? byte + 32 : byte
                },
                as: UTF8.self
            )
            switch word {
            case "begin", "case":
                depth += 1
            case "else":
                depth = max(1, depth)
                closers.insert(lower)
            case "end":
                depth = max(0, depth - 1)
                closers.insert(lower)
            case "if", "while":
                if significant.first == lower {
                    conditionEnd = upper
                }
            default:
                continue
            }
            points.append((upper, depth, word == "end"))
        }
        self.points = points
        self.closers = closers
        self.significant = significant
        self.code = code
        self.conditionEnd = conditionEnd
        isCondition =
            conditionEnd.map {
                (significant.last ?? -1) >= $0 && depth == 0 && points.last?.ended != true
                    && significant.last.map {
                        code[$0] != 59
                    } == true
            } == true
    }

    /// 业务作用：真实回车只按已输入的块和条件准备增加或减少，后继闭合词可以形成完整内外两行。
    /// 参数说明:
    /// - offset: 实际插入边界相对当前行的位置。
    /// - end: 完整替换范围结束边界。
    /// - previous: 插入点前最后一个有效代码字节的位置。
    /// - allowFollowing: 后继是否仍具有代码资格。
    /// - precedingCondition: 前一行是否为尚未获得单行正文的条件头。
    /// 返回：增加、减少、成对展开或继承动作，不修改正文。
    func action(
        offset: Int,
        end: Int,
        previous: Int?,
        allowFollowing: Bool,
        precedingCondition: Bool
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
        let point = lower > 0 ? points[lower - 1] : nil
        var next: Int?
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
            if lower < significant.count {
                next = significant[lower]
            }
        }
        let closes =
            next.map {
                closers.contains($0)
            } == true
        if (point?.depth ?? 0) > 0 {
            return closes ? .expandPair : .increase
        }
        if closes {
            return .decrease
        }
        if let conditionEnd,
            previous.map({
                $0 >= conditionEnd && code[$0] != 59
            }) == true, point?.ended != true
        {
            return .increase
        }
        return precedingCondition ? .decrease : .inherit
    }
}
