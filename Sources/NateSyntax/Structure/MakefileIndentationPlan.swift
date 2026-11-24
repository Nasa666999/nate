import Foundation
import NateCore

enum MakefileIndentationPlan {
    private enum Block {
        case conditional
        case definition
    }

    private struct Scope {
        let block: Block
        let prefix: String
        var finalAlternative = false
    }

    /// 业务作用：从同一固定 Makefile 确认条件、define 和真实配方边界，维护整次回车的原空白。
    /// 参数说明:
    /// - snapshot: 全部替换位置属于的完整固定正文。
    /// - ranges: 上游已经复验的真实替换范围。
    /// - deadline: 前置传播、动作和最终核心事务共享的截止。
    /// - permit: 当前输入仍可继续准备的资格。
    /// 返回：完整逐目标动作，语法未知或配方保持原缩进，资源或资格超限拒绝全部目标。
    static func actions(
        snapshot: DocumentSnapshot,
        ranges: [ByteRange],
        deadline: ContinuousClock.Instant,
        permit: @escaping @Sendable () -> Bool
    ) throws -> [ByteRange: NewlineIndentationAction] {
        /// 业务作用：让实际续接和所有目标使用同一个取消和时限。
        /// 参数说明: 无。
        /// 返回：当前输入具备继续权限时通过，失效时终止整次准备。
        func check() throws {
            try Task.checkCancellation()
            guard permit(), ContinuousClock.now < deadline else {
                throw NateError.message("Makefile 结构缩进已取消或超过共同截止。")
            }
        }
        let text = snapshot.text
        var targets: [Int: [ByteRange]] = [:]
        for range in ranges {
            try check()
            targets[text.lineNumber(at: range.lower), default: []].append(range)
        }
        let last = targets.keys.max() ?? 0
        guard last < 1_048_576 else {
            throw NateError.message("Makefile 结构缩进的前置传播超过一百万行。")
        }
        var sourceRemaining = 64 * 1_048_576
        var prefixesRemaining = 1_048_576
        var logical: [UInt8] = []
        var origin = ""
        var continued = false
        var continuedRecipe = false
        var scopes: [Scope] = []
        var recipePrefix: UInt8? = 9
        var recipePossible = false
        var canRestoreRecipePrefix = true
        var result: [ByteRange: NewlineIndentationAction] = [:]
        for line in 0...last {
            try check()
            let complete = text.lineRange(line)
            let body = text.lineRange(line, includeEnding: false)
            // 防止超长上下文先建立部分动作，后续目标耗尽预算时保留全部原文。
            guard complete.count <= 1_048_576, complete.count <= sourceRemaining else {
                throw NateError.message("Makefile 结构缩进超过单行 1 MiB 或前置原文 64 MiB。")
            }
            sourceRemaining -= complete.count
            let bytes = text.bytes(in: body)
            let inputs = targets[line] ?? []
            let carries = try complete.count > body.count && continuation(in: bytes, check: check)
            let inDefinition = scopes.last?.block == .definition
            let beginsWithRecipePrefix = recipePrefix.map { bytes.first == $0 } == true
            if continuedRecipe || !continued && (recipePossible || inDefinition) && beginsWithRecipePrefix {
                // 规则内的配方和 define 内的配方形态都保持字面，真实首字节与续行决定作用范围。
                continuedRecipe = carries
                for target in inputs {
                    try check()
                    result[target] = .inherit
                }
                continue
            }
            if !continued {
                let prefix = bytes.prefix {
                    $0 == 9 || $0 == 32
                }
                guard prefix.count <= prefixesRemaining else {
                    throw NateError.message("Makefile 结构缩进原始前缀超过 1 MiB。")
                }
                prefixesRemaining -= prefix.count
                origin = String(decoding: prefix, as: UTF8.self)
            }
            let previousBytes = logical.count
            let content = bytes.dropLast(carries ? 1 : 0)
            guard content.count <= 1_048_576 - previousBytes - (carries ? 1 : 0) else {
                throw NateError.message("Makefile 续接语句超过 1 MiB。")
            }
            logical.append(contentsOf: content)
            if carries {
                logical.append(32)
                continued = true
                for target in inputs {
                    try check()
                    result[target] = .inherit
                }
                continue
            }
            let full = try MakefileIndentationSyntax.code(logical[...], check: check)
            let continuedComment =
                try continued
                && MakefileIndentationSyntax.commentStart(logical.prefix(previousBytes), check: check) != nil
            let change = inDefinition ? .unchanged : MakefileIndentationSyntax.recipePrefix(full)
            switch change {
            case .unchanged:
                break
            case .known(let marker) where canRestoreRecipePrefix && scopes.isEmpty:
                recipePrefix = marker
            case .known, .unresolved:
                recipePrefix = nil
            }
            let event = try MakefileIndentationSyntax.event(
                full,
                insideDefinition: inDefinition,
                check: check
            )
            if recipePrefix == nil {
                // 配方前缀取决于未求值的表达式或条件，旧块不再具备安全对齐的来源证据。
                if !scopes.isEmpty {
                    canRestoreRecipePrefix = false
                }
                switch event {
                case .conditional, .definition:
                    // 前缀未定时无法确认后续赋值在全局生效，也不能让它恢复旧对齐权限。
                    canRestoreRecipePrefix = false
                default:
                    break
                }
                scopes.removeAll()
            }
            for target in inputs {
                try check()
                let offset = min(body.count, target.lower - body.lower)
                guard recipePrefix != nil, !continuedComment,
                    offset < 1 || offset == bytes.count
                        || !wordByte(bytes[offset - 1]) || !wordByte(bytes[offset])
                else {
                    result[target] = .inherit
                    continue
                }
                let before = logical.prefix(previousBytes + offset)
                let event = try MakefileIndentationSyntax.event(
                    before,
                    insideDefinition: inDefinition,
                    check: check
                )
                var indent = action(event, origin: origin, scope: scopes.last)
                if indent == .inherit, !continued, target.upper <= body.upper,
                    MakefileIndentationSyntax.trim(before).isEmpty
                {
                    let following = try MakefileIndentationSyntax.event(
                        logical[(target.upper - body.lower)...],
                        insideDefinition: inDefinition,
                        check: check
                    )
                    switch following {
                    case .endConditional, .endDefinition:
                        indent = action(following, origin: origin, scope: scopes.last)
                    default:
                        break
                    }
                }
                result[target] = indent
            }
            if recipePrefix != nil {
                if !inDefinition {
                    switch event {
                    case .definition where scopes.isEmpty:
                        recipePossible = false
                    case .neutral:
                        let context = try MakefileIndentationSyntax.recipeContext(full, check: check)
                        if context == .afterRule {
                            recipePossible = true
                        }
                        else if context == .outsideRule, scopes.isEmpty {
                            // 条件内的赋值只有生效分支才能结束已有规则，静态判断继续保留其配方边界。
                            recipePossible = false
                        }
                    default:
                        break
                    }
                }
                // 本语句全部光标先得到旧块证据，之后才推进实际开端、分支或关闭给后续行。
                try apply(event, origin: origin, scopes: &scopes)
            }
            logical.removeAll(keepingCapacity: true)
            continued = false
        }
        try check()
        return result
    }

    /// 业务作用：反斜杠成对时只保留字面，奇数尾部才能让实际物理行继续。
    /// 参数说明:
    /// - bytes: 排除行尾的原始物理行。
    /// - check: 当前动作的共同继续资格。
    /// 返回：真实最后字节结束在未配对的反斜杠时为真。
    private static func continuation(in bytes: [UInt8], check: () throws -> Void) throws -> Bool {
        var odd = false
        for byte in bytes.reversed() {
            try check()
            guard byte == 92 else {
                break
            }
            odd.toggle()
        }
        return odd
    }

    /// 业务作用：只有不会把 Make 行内名称切断的真实边界才可触发结构缩进。
    /// 参数说明:
    /// - byte: 插入点相邻的一个原字节。
    /// 返回：可能属于当前名称或变量时为真。
    private static func wordByte(_ byte: UInt8) -> Bool {
        ![9, 32, 35, 40, 41, 44, 58, 61, 123, 125].contains(byte)
    }

    /// 业务作用：实际分支及关闭使用所属块的原空白，新块使用自己的首物理行。
    /// 参数说明:
    /// - event: 已证明的当前语句角色。
    /// - origin: 当前完整语句开端的原空格或 Tab。
    /// - scope: 处理本语句前仍有效的最内层结构。
    /// 返回：确切的原前缀及相对层次；没有所属结构时继承当前行。
    private static func action(
        _ event: MakefileIndentationSyntax.Event,
        origin: String,
        scope: Scope?
    ) -> NewlineIndentationAction {
        switch event {
        case .conditional, .definition:
            return .align(prefix: origin, levels: 1)
        case .alternative:
            guard let scope, scope.block == .conditional, !scope.finalAlternative else {
                return .inherit
            }
            return .align(prefix: scope.prefix, levels: 1)
        case .endConditional where scope?.block == .conditional,
            .endDefinition where scope?.block == .definition:
            if let scope {
                return .align(prefix: scope.prefix, levels: 0)
            }
            return .inherit
        default:
            return .inherit
        }
    }

    /// 业务作用：确认完整语句以后才改变活动范围，定义内的字面和不匹配关闭不能授予后继结构权限。
    /// 参数说明:
    /// - event: 当前语句的完整角色。
    /// - origin: 当前语句从其首物理行保存的原空白。
    /// - scopes: 之后语句实际可用的活动块。
    /// 返回：更新有界活动结构，超深时整体停止。
    private static func apply(
        _ event: MakefileIndentationSyntax.Event,
        origin: String,
        scopes: inout [Scope]
    ) throws {
        switch event {
        case .conditional, .definition:
            guard scopes.count < 4096 else {
                throw NateError.message("Makefile 结构缩进超过 4096 层活动块。")
            }
            if case .definition = event {
                scopes.append(Scope(block: .definition, prefix: origin))
            }
            else {
                scopes.append(Scope(block: .conditional, prefix: origin))
            }
        case .alternative(let final):
            if final, scopes.last?.block == .conditional {
                scopes[scopes.count - 1].finalAlternative = true
            }
        case .endConditional where scopes.last?.block == .conditional,
            .endDefinition where scopes.last?.block == .definition:
            scopes.removeLast()
        default:
            break
        }
    }
}
