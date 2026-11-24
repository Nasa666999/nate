import Foundation
import NateCore

struct BashIndentationState {
    private enum Phase {
        case then
        case conditionalBody
        case elseBody
        case iterator
        case iteratorEnd
        case launchLoop
        case loopBody
        case caseValue
        case caseKeyword
        case casePattern
        case caseBody
        case compound
    }

    private struct Block {
        var phase: Phase
        let prefix: String
        let level: Int
    }

    private enum FunctionHeader {
        case name
        case possibleName
        case explicitName
        case parameters
    }

    private var blocks: [Block] = []
    private var commandStart = true
    private var redirection = false
    private var testExpression = false
    private var groupDepth = 0
    private var caseHasPattern = false
    private var casePatternDepth = 0
    private var functionHeader: FunctionHeader?
    private var lineAction: NewlineIndentationAction = .inherit

    /// 业务作用：结束物理行局部决定，完整逻辑换行开启下一条命令，续行仍属于原命令前缀。
    /// 参数说明:
    /// - continuation: 前一物理行仍处于引用或反斜杠续行。
    /// 返回：只清除本行建议，合法未闭合的结构仍保留原开端和权限。
    mutating func beginLine(afterContinuation continuation: Bool) {
        lineAction = .inherit
        if !continuation {
            commandStart = true
            redirection = false
            if functionHeader == .possibleName || functionHeader == .name {
                functionHeader = nil
            }
        }
    }

    /// 业务作用：按 Shell 命令位置和当前块阶段推进合法结构，普通参数中的同名词不改变缩进。
    /// 参数说明:
    /// - token: 已通过同一原始词法状态确定的完整词元。
    /// - prefix: 该逻辑开端所在真实物理行的空白前缀。
    /// 返回：记录已完成的结构动作；过深或无法安全记录的上下文拒绝整份准备。
    mutating func consume(_ token: BashIndentationToken, prefix: String) throws {
        if testExpression {
            if token.kind == .word("]]") {
                testExpression = false
                commandStart = false
            }
            return
        }
        if groupDepth > 0 {
            switch token.kind {
            case .openGroup:
                try openGroup()
            case .closeGroup:
                groupDepth -= 1
                commandStart = false
            default:
                break
            }
            return
        }
        if blocks.last?.phase == .casePattern {
            switch token.kind {
            case .word("esac") where !caseHasPattern:
                closeBlock()
            case .openGroup where !caseHasPattern:
                caseHasPattern = true
            case .openGroup:
                guard casePatternDepth < 256 else {
                    throw NateError.message("Bash 结构换行的 case 模式括号超过 256 层。")
                }
                casePatternDepth += 1
            case .closeGroup where casePatternDepth > 0:
                // 扩展模式内的括号只结束匹配模式分组，不能提前打开分支正文。
                casePatternDepth -= 1
            case .closeGroup where caseHasPattern:
                setPhase(.caseBody, indentation: 2)
                commandStart = true
            case .word:
                caseHasPattern = true
            default:
                break
            }
            return
        }
        switch token.kind {
        case .word(let name):
            try consumeWord(name, opaque: token.opaque, prefix: prefix)
        case .separator:
            commandStart = true
            redirection = false
            functionHeader = nil
        case .openGroup:
            functionHeader = nil
            try openGroup()
        case .closeGroup:
            commandStart = false
        case .emptyGroup:
            if functionHeader == .possibleName || functionHeader == .explicitName {
                functionHeader = .parameters
            }
        case .caseEnd:
            if blocks.last?.phase == .caseBody {
                setPhase(.casePattern, indentation: 1)
                caseHasPattern = false
                casePatternDepth = 0
            }
            commandStart = true
        case .redirection:
            redirection = true
        }
    }

    /// 业务作用：以实际插入点之前完成的块为准，仅在资格明确时为紧邻闭合提供对齐。
    /// 参数说明:
    /// - next: 选区之后紧邻的、已确认未引用的原词。
    /// 返回：当前行结构动作，或没有完成证据时沿用原缩进。
    func action(before next: BashIndentationToken?) -> NewlineIndentationAction {
        guard !testExpression, groupDepth == 0 else {
            return .inherit
        }
        guard lineAction == .inherit, commandStart, !redirection, let block = blocks.last else {
            return lineAction
        }
        switch (block.phase, next?.kind) {
        case (.conditionalBody, .word("fi")), (.elseBody, .word("fi")),
            (.loopBody, .word("done")), (.caseBody, .word("esac")),
            (.casePattern, .word("esac")), (.compound, .word("}")):
            return .align(prefix: block.prefix, levels: block.level)
        default:
            return .inherit
        }
    }

    /// 业务作用：判断语法词在哪个原始命令或块阶段拥有控制含义。
    /// 参数说明:
    /// - name: 完整裸词；引用、转义或普通长词以空值表示。
    /// - opaque: 是否缺少未引用命令名的词法资格。
    /// - prefix: 此行的原始前导空白。
    /// 返回：关闭、进入或继续原结构，遇到不符合语法位置的词按普通参数保留。
    private mutating func consumeWord(_ name: String?, opaque: Bool, prefix: String) throws {
        if redirection {
            redirection = false
            return
        }
        if functionHeader == .name, !opaque {
            functionHeader = .explicitName
            return
        }
        if name == "{", functionHeader == .explicitName || functionHeader == .parameters {
            functionHeader = nil
            try open(.compound, prefix: prefix)
            setPhase(.compound, indentation: 1)
            commandStart = true
            return
        }
        functionHeader = nil
        switch blocks.last?.phase {
        case .caseValue:
            setPhase(.caseKeyword)
            return
        case .caseKeyword:
            if name == "in" {
                setPhase(.casePattern, indentation: 1)
                caseHasPattern = false
                casePatternDepth = 0
            }
            else {
                // 不完整 case 开头仍在编辑。撤下这层准备，避免借到后续不相关的 in。
                blocks.removeLast()
            }
            return
        case .iterator:
            setPhase(.iteratorEnd)
            return
        case .iteratorEnd:
            if name == "do" {
                setPhase(.loopBody, indentation: 1)
                commandStart = true
                return
            }
            setPhase(.launchLoop)
        default:
            break
        }
        guard commandStart else {
            return
        }
        switch (blocks.last?.phase, name) {
        case (.then, "then"):
            setPhase(.conditionalBody, indentation: 1)
        case (.conditionalBody, "elif"):
            setPhase(.then, indentation: 0)
        case (.conditionalBody, "else"):
            setPhase(.elseBody, indentation: 1)
        case (.conditionalBody, "fi"), (.elseBody, "fi"), (.loopBody, "done"),
            (.caseBody, "esac"), (.compound, "}"):
            closeBlock()
        case (.launchLoop, "do"):
            setPhase(.loopBody, indentation: 1)
        default:
            switch name {
            case "if":
                try open(.then, prefix: prefix)
            case "while", "until":
                try open(.launchLoop, prefix: prefix)
            case "for", "select":
                try open(.iterator, prefix: prefix)
                commandStart = false
            case "case":
                try open(.caseValue, prefix: prefix)
                commandStart = false
            case "function":
                functionHeader = .name
                commandStart = false
            case "{":
                try open(.compound, prefix: prefix)
                setPhase(.compound, indentation: 1)
            case "[[":
                testExpression = true
            case "!", "time":
                break
            default:
                if !opaque {
                    functionHeader = .possibleName
                }
                commandStart = false
            }
        }
    }

    /// 业务作用：在当前原始控制块里切换阶段，缩进沿所属开端的混合空白，不借用外层。
    /// 参数说明:
    /// - phase: 由合法控制词确定的下一阶段。
    /// - indentation: 需要发布本行建议时相对于开端的层数。
    /// 返回：只推进当前块，必要时保存明确对齐动作。
    private mutating func setPhase(_ phase: Phase, indentation: Int? = nil) {
        guard let index = blocks.indices.last else {
            return
        }
        blocks[index].phase = phase
        if let indentation {
            lineAction = .align(prefix: blocks[index].prefix, levels: blocks[index].level + indentation)
        }
    }

    /// 业务作用：闭合当前匹配块并复用其原始缩进，连续命令须重新取得命令起始资格。
    /// 参数说明: 无。
    /// 返回：当前层闭合，下一行对齐到同一块开端。
    private mutating func closeBlock() {
        if let block = blocks.popLast() {
            lineAction = .align(prefix: block.prefix, levels: block.level)
        }
        commandStart = false
    }

    /// 业务作用：仅给当前文件的完整块保存原前缀，避免重复复制深层或超长行。
    /// 参数说明:
    /// - phase: 已证明的块种类和阶段。
    /// - prefix: 原开端行的纯空白。
    /// 返回：进入一层结构，累计层数超限则整份拒绝。
    private mutating func open(_ phase: Phase, prefix: String) throws {
        guard blocks.count < 256 else {
            throw NateError.message("Bash 结构换行的块嵌套超过 256 层。")
        }
        if case .align(let base, let levels) = lineAction {
            blocks.append(Block(phase: phase, prefix: base, level: levels))
        }
        else {
            blocks.append(Block(phase: phase, prefix: prefix, level: 0))
        }
    }

    /// 业务作用：括号组、数组和算术表达式的词没有外层命令资格。
    /// 参数说明: 无。
    /// 返回：保存完整分组深度；超限时停止准备，防止错配后使用虚假外层证据。
    private mutating func openGroup() throws {
        guard groupDepth < 256 else {
            throw NateError.message("Bash 结构换行的括号组嵌套超过 256 层。")
        }
        if groupDepth == 0, blocks.last?.phase == .iterator {
            setPhase(.launchLoop)
        }
        groupDepth += 1
    }
}
