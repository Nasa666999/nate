import Foundation
import NateCore

enum FortranIndentationPlan {
    private typealias Block = FortranIndentationLine.Block

    private struct Frame {
        let block: Block
        let name: String?
        let prefix: ByteRange

        /// 业务作用：闭合必须属于当前真实结构，同名变量、不同名字的块或单独 END 不能结束任意一层。
        /// 参数说明:
        /// - requested: 闭合或分支实际声明的块类别；裸 END 省略类别。
        /// - name: 已确认的可选结构名。
        /// - closing: 是否需要验证闭合端的命名约束。
        /// 返回：类别和要求的原声明名称均匹配时为真。
        func matches(_ requested: Block?, name: String?, closing: Bool = true) -> Bool {
            guard requested == block || requested == nil && block.usesBareEnd else {
                return false
            }
            if let name {
                return self.name == name
            }
            return !closing || self.name == nil || block.usesBareEnd || block == .interface
        }
    }

    /// 业务作用：自由格式 Fortran 换行使用原生词法已确认的完整结构，所有光标共享同一正文和准备期限。
    /// 参数说明:
    /// - snapshot: 所有真实输入目标固定的不可变正文。
    /// - language: 实际自由格式 Fortran 词表及样式资源。
    /// - ranges: 已验证的普通或矩形真实替换范围。
    /// - deadline: 前置词法、原前缀、事务及提交的实际共同截止。
    /// - permit: 本次编辑继续有效的资格。
    /// 返回：完整逐目标缩进动作；固定格式、未确认续行及特殊声明不借用冲突结构。
    static func actions(
        snapshot: DocumentSnapshot,
        language: LanguageDefinition,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：原生传播和全部光标只使用本次输入的继续资格。
        /// 参数说明: 无。
        /// 返回：操作仍有效时继续；过期或取消停止整份计划。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Fortran 结构缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var byLine: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            byLine[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = byLine.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Fortran 结构缩进的前置传播超过一百万行。")
        }
        let scanner = SyntaxScanner(language: language, snapshot: snapshot, deadline: deadline)
        var lexical = SyntaxState()
        var sourcesRemaining = 64 * 1_048_576
        var prefixesRemaining = 1_048_576
        var prefixCache: [ByteRange: String] = [:]
        var scopes: [Frame] = []
        var continued = false
        var result: [ByteRange: NewlineIndentationAction] = [:]

        /// 业务作用：真实开端的混合空白只读取一次，所有编辑目标共同使用容量。
        /// 参数说明:
        /// - range: 已确认的原始水平空白范围。
        /// 返回：完整原空白；超过一次输入的共同容量整批拒绝。
        func prefix(_ range: ByteRange) throws -> String {
            if let cached = prefixCache[range] {
                return cached
            }
            guard range.count <= prefixesRemaining else {
                throw NateError.message("Fortran 结构缩进需要的完整原前缀超过 1 MiB。")
            }
            prefixesRemaining -= range.count
            let value = text.text(in: range)
            prefixCache[range] = value
            return value
        }

        for line in 0...last {
            try check()
            let physical = text.lineRange(line)
            let content = text.lineRange(line, includeEnding: false)
            // 整个前置范围必须先具备读取资格，任何目标失败都不能留下先前光标的部分缩进。
            guard physical.count <= 1_048_576, physical.count <= sourcesRemaining else {
                throw NateError.message("Fortran 结构缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            sourcesRemaining -= physical.count
            let source = text.text(in: physical)
            let tokens = scanner.highlight(source, base: physical.lower, state: &lexical)
            if let error = lexical.diagnostic {
                throw NateError.message(error)
            }
            let row = try FortranIndentationLine(
                bytes: Array(source.utf8.prefix(content.count)),
                range: content,
                tokens: tokens,
                check: check
            )
            let targets = byLine[line] ?? []
            let requiresFallback =
                continued || row.beginsContinuation || row.endsContinuation
                || row.crossesStatements || row.directive
            continued = row.endsContinuation || continued && row.atoms.isEmpty
            if requiresFallback {
                // 多条语句、跨行续接和条件编译可能改变关闭关系，旧块不能在不完整证据之后继续授权。
                scopes.removeAll()
                for target in targets {
                    try check()
                    result[target] = .inherit
                }
                continue
            }
            for target in targets {
                try check()
                guard let before = row.prefixAtoms(at: min(target.lower, content.upper)) else {
                    result[target] = .inherit
                    continue
                }
                let event = try FortranIndentationLine.classify(before, check: check)
                switch event {
                case .opening:
                    result[target] = .align(prefix: try prefix(row.prefix), levels: 1)
                case .branch(let block, let name, let levels):
                    if let scope = scopes.last, scope.matches(block, name: name, closing: false) {
                        result[target] = .align(prefix: try prefix(scope.prefix), levels: levels)
                    }
                    else {
                        result[target] = .inherit
                    }
                case .closing(let block, let name):
                    if let scope = scopes.last, scope.matches(block, name: name) {
                        result[target] = .align(prefix: try prefix(scope.prefix), levels: 0)
                    }
                    else {
                        result[target] = .inherit
                    }
                case .neutral:
                    if before.isEmpty, target.upper < content.upper,
                        let tail = row.suffixAtoms(at: target.upper),
                        case .closing(let block, let name) = try FortranIndentationLine.classify(
                            tail,
                            check: check
                        ),
                        let scope = scopes.last, scope.matches(block, name: name)
                    {
                        result[target] = .align(prefix: try prefix(scope.prefix), levels: 0)
                    }
                    else {
                        result[target] = .inherit
                    }
                }
            }
            let event = try FortranIndentationLine.classify(row.atoms[...], check: check)
            switch event {
            case .opening(let block, let name):
                guard scopes.count < 4096 else {
                    throw NateError.message("Fortran 结构缩进超过 4096 层活动块。")
                }
                scopes.append(Frame(block: block, name: name, prefix: row.prefix))
            case .closing(let block, let name):
                if let scope = scopes.last, scope.matches(block, name: name) {
                    scopes.removeLast()
                }
                else {
                    // 未匹配的关闭可能已经结束外层的语义范围，后续输入不能再沿这个不确定的栈对齐。
                    scopes.removeAll()
                }
            case .branch, .neutral:
                break
            }
        }
        try check()
        return result
    }
}
