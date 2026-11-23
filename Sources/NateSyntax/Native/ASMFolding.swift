import Foundation
import NateCore

enum ASMFolding {
    /// 业务作用：汇编将同源完整词法分类转换为指令和注释折叠，开闭词表及注释标记只能引用本轮固定正文。
    /// 参数说明:
    /// - snapshot: 本轮固定的完整正文。
    /// - language: 当前完整八组关键字与十七种样式。
    /// - deadline: 原文读取、词法、层级计算和范围发布共同的截止。
    /// 返回：至多 65536 个完整多行范围；正文、行数、层级或计算证据不足时拒绝全部折叠。
    static func regions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        deadline: ContinuousClock.Instant
    ) throws -> [FoldRegion] {
        let tree = snapshot.text
        guard tree.byteCount <= 64 * 1024 * 1024, tree.lineCount <= 1_048_576 else {
            throw NateError.message("汇编 折叠超过正文或物理行数预算。")
        }
        guard let rules = ASMRules(language: language, deadline: deadline) else {
            throw NateError.message("汇编折叠缺少完整八组规则与样式。")
        }
        var budget = ANSILexingBudget(deadline: deadline, maximumSteps: 134_217_728)
        try budget.check()
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var state = SyntaxState()
        var classes = Array(repeating: UInt8(0), count: tree.byteCount)
        var starts: [Int] = []
        for line in 0..<tree.lineCount {
            try budget.check()
            let range = try ANSILexing.physicalRange(tree.lineRange(line), tree: tree, budget: &budget)
            guard range.count <= 1_048_576 else {
                throw NateError.message("汇编 折叠涉及超过 1 MiB 的物理行。")
            }
            starts.append(range.lower)
            let tokens = scanner.highlight(tree.text(in: range), base: range.lower, state: &state)
            // 未确认词法证据不能借部分关键字隐藏正文，任一物理行失败即撤销整份折叠候选。
            guard state.diagnostic == nil else {
                throw NateError.message(state.diagnostic ?? "汇编 折叠缺少完整词法证据。")
            }
            for token in tokens {
                guard token.lexicalStyle.hasPrefix("asm:"),
                    let style = UInt8(token.lexicalStyle.dropFirst(4)), style <= 16,
                    token.range.lower >= range.lower, token.range.upper <= range.upper
                else {
                    throw NateError.message("汇编 折叠缺少当前物理行的明确样式身份。")
                }
                for position in token.range.lower..<token.range.upper {
                    try budget.consume()
                    classes[position] = style
                }
            }
        }
        let raw = tree.bytes(in: ByteRange(0, tree.byteCount))
        var folding = ASMFoldScanner(
            bytes: raw,
            styles: classes,
            starts: starts,
            rules: rules,
            budget: budget
        )
        let levels = try folding.levels()
        budget = folding.budget
        var ends = Array(repeating: levels.count - 1, count: levels.count)
        var stack: [Int] = []
        for index in levels.indices {
            try budget.consume()
            while let parent = stack.last, levels[index] & 4095 <= levels[parent] & 4095 {
                ends[parent] = index - 1
                stack.removeLast()
            }
            if levels[index] & 8192 != 0 {
                stack.append(index)
            }
        }
        var output: [FoldRegion] = []
        for index in levels.indices where levels[index] & 8192 != 0 {
            try budget.consume()
            let end = ends[index]
            if end <= index {
                continue
            }
            guard output.count < 65_536 else {
                throw NateError.message("汇编 折叠超过 65536 个完整范围。")
            }
            output.append(
                FoldRegion(
                    range: ByteRange(tree.lineRange(index).lower, tree.lineRange(end).upper),
                    startLine: index,
                    endLine: end,
                    level: 0
                )
            )
        }
        try budget.check()
        return output
    }
}
