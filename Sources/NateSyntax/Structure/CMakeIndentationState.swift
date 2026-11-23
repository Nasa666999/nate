import Foundation
import NateCore

struct CMakeIndentationState {
    var quote = false
    var bracket: Int?
    var bracketComment = false
    var bracketProgress = 0
    var bracketOpeningEnd = 0
    var lineComment = false
    var escaped = false
    var depth = 0
    var command = ""
    var argumentStart = true
    var candidate: [UInt8] = []
    var candidateLong = false
    var candidateStart = 0
    var candidateEnded = false
    var commandAllowed = true

    static let openers: Set<String> = [
        "if", "elseif", "else", "while", "foreach", "function", "macro", "block",
    ]
    static let closers: Set<String> = [
        "elseif", "else", "endif", "endwhile", "endforeach", "endfunction", "endmacro", "endblock",
    ]

    /// 业务作用：只有对应块的闭合或分支才能展开内外两行，不把其它结构的结束命令当成配对证据。
    /// 参数说明:
    /// - opening: 插入点前已经完整结束的块命令。
    /// - closing: 插入点后具有真实调用资格的闭合命令。
    /// 返回：属于同一结构时为真，缺少或不匹配时为假。
    static func matches(_ opening: String, closing: String?) -> Bool {
        guard let closing else {
            return false
        }
        if ["if", "elseif", "else"].contains(opening) {
            return ["endif", "elseif", "else"].contains(closing)
        }
        return closing == "end" + opening
    }

    /// 业务作用：逐物理行保留 CMake 引号、括号参数及命令上下文，行注释和命令名称不越过真实行界。
    /// 参数说明: 无。
    /// 返回：跨行字面和未完成调用保持，同行候选与行注释清空。
    mutating func beginLine() {
        lineComment = false
        bracketOpeningEnd = 0
        candidate = []
        candidateLong = false
        candidateEnded = false
        commandAllowed = depth == 0 && !quote && bracket == nil
        if !quote && bracket == nil {
            argumentStart = true
        }
    }

    /// 业务作用：仅真实代码区内的命令调用形成结构证据，字面和注释里的命令名称不授予缩进资格。
    /// 参数说明:
    /// - bytes: 已受单行容量约束的完整原字节。
    /// - index: 当前行内的原字节位置。
    /// - deadline: 本轮所有光标共用的截止。
    /// - permit: 本次输入继续准备的资格。
    /// 返回：当前字节闭合的命令名，以及实际开启调用的名称和起点；其它字节不产生事件。
    mutating func consume(
        _ bytes: [UInt8],
        at index: Int,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> (completed: String?, started: (name: String, lower: Int)?) {
        let byte = bytes[index]
        if lineComment {
            return (nil, nil)
        }
        if let equals = bracket {
            if index < bracketOpeningEnd {
                return (nil, nil)
            }
            if byte == 93 {
                if bracketProgress == equals + 1 {
                    bracket = nil
                    bracketProgress = 0
                    if bracketComment && depth == 0 {
                        commandAllowed = true
                    }
                }
                else {
                    bracketProgress = 1
                }
            }
            else if byte == 61 && bracketProgress > 0 && bracketProgress <= equals {
                bracketProgress += 1
            }
            else {
                bracketProgress = 0
            }
            return (nil, nil)
        }
        if escaped {
            escaped = false
            return (nil, nil)
        }
        if byte == 92 {
            escaped = true
            argumentStart = false
            candidate = []
            candidateLong = false
            commandAllowed = false
            return (nil, nil)
        }
        if quote {
            if byte == 34 {
                quote = false
            }
            return (nil, nil)
        }
        if byte == 34 {
            quote = true
            argumentStart = false
            candidate = []
            candidateLong = false
            commandAllowed = false
            return (nil, nil)
        }
        let bracketStart = byte == 35 ? index + 1 : index
        if byte == 35 || byte == 91 && (argumentStart || depth == 0) {
            if let opening = try Self.opening(bytes, at: bracketStart, deadline: deadline, permit: permit) {
                bracket = opening.equals
                bracketComment = byte == 35
                bracketProgress = 0
                bracketOpeningEnd = opening.end
                argumentStart = false
            }
            else if byte == 35 {
                lineComment = true
            }
            candidate = []
            candidateLong = false
            commandAllowed = false
            return (nil, nil)
        }
        if depth > 0 {
            argumentStart = [9, 10, 13, 32, 40, 41].contains(byte)
            if byte == 40 {
                guard depth < 4096 else {
                    throw NateError.message("CMake 语言缩进的参数括号超过 4096 层。")
                }
                depth += 1
            }
            else if byte == 41 {
                depth -= 1
                if depth == 0 {
                    let completed = command
                    command = ""
                    commandAllowed = true
                    return (completed, nil)
                }
            }
            return (nil, nil)
        }
        if byte == 40 && !candidate.isEmpty {
            command = candidateLong ? "" : String(decoding: candidate, as: UTF8.self)
            let lower = candidateStart
            candidate = []
            candidateLong = false
            candidateEnded = false
            depth = 1
            argumentStart = true
            commandAllowed = false
            return (nil, (command, lower))
        }
        if byte == 32 || byte == 9 {
            candidateEnded = !candidate.isEmpty
            return (nil, nil)
        }
        let letter = byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122 || byte == 95
        let digit = byte >= 48 && byte <= 57
        if commandAllowed && !candidateEnded && (letter || digit && !candidate.isEmpty) {
            if candidate.count < 64 {
                if candidate.isEmpty {
                    candidateStart = index
                }
                candidate.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
            }
            else {
                candidateLong = true
            }
        }
        else {
            candidate = []
            candidateLong = false
            commandAllowed = false
        }
        return (nil, nil)
    }

    /// 业务作用：CMake 方括号字面与注释按相同等号数闭合，有限原文不被补成未存在的定界符。
    /// 参数说明:
    /// - bytes: 当前完整物理行。
    /// - start: 可能的首个左方括号。
    /// - deadline: 输入共同截止。
    /// - permit: 本次输入继续准备的资格。
    /// 返回：完整开端的等号数和结束位置；不构成开端时为空，取消或超时则抛错。
    private static func opening(
        _ bytes: [UInt8],
        at start: Int,
        deadline: ContinuousClock.Instant,
        permit: @Sendable () -> Bool
    ) throws -> (equals: Int, end: Int)? {
        guard start < bytes.count, bytes[start] == 91 else {
            return nil
        }
        var end = start + 1
        while end < bytes.count && bytes[end] == 61 {
            if end & 255 == 0 {
                try CMakeIndentationPlan.check(deadline: deadline, permit: permit)
            }
            end += 1
        }
        guard end < bytes.count, bytes[end] == 91 else {
            return nil
        }
        return (end - start - 1, end + 1)
    }
}
