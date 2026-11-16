import Foundation
import NateCore

enum Substitution {
    /// 业务作用：解释 Boost 风格捕获、上下文与大小写替换，空替换合法。
    /// 参数说明:
    /// - format: 用户替换表达式。
    /// - hit: 已参与捕获与命名映射。
    /// - input: 原快照 UTF-16 上下文。
    /// - depth: 内部分组展开深度。
    /// 返回：完整替换文字；格式错误在提交前失败。
    static func expand(_ format: String, hit: SearchHit, input: [UInt16], depth: Int = 0) throws -> String {
        guard depth < 128 else {
            throw NateError.message("替换格式嵌套超过 128 层。")
        }
        let chars = Array(format)
        var i = 0
        var result = ""
        var mode = ""
        var one = ""
        /// 业务作用：读取实际参与捕获的原文本，不将未参与组登记为空捕获。
        /// 参数说明:
        /// - id: 捕获组号。
        /// 返回：参与捕获的正文，未参与组只在输出时产生空文字。
        func captured(_ id: Int) -> String {
            guard let r = hit.captures[id], r.location >= 0, r.location + r.length <= input.count else {
                return ""
            }
            return String(decoding: input[r.location..<(r.location + r.length)], as: UTF16.self)
        }
        /// 业务作用：按当前替换大小写状态追加文字。
        /// 参数说明:
        /// - text: 已解释的替换片段。
        /// 返回：更新输出及单次大小写状态。
        func append(_ text: String) {
            var text = text
            if mode == "L" {
                text = text.lowercased()
            }
            if mode == "U" {
                text = text.uppercased()
            }
            if !one.isEmpty, let first = text.first {
                text =
                    (one == "l" ? String(first).lowercased() : String(first).uppercased()) + text.dropFirst()
                one = ""
            }
            result += text
        }
        while i < chars.count {
            let ch = chars[i]
            i += 1
            if ch == "(" {
                let content = try group(chars, index: &i)
                let selected = try conditional(content, hit: hit)
                append(try expand(selected, hit: hit, input: input, depth: depth + 1))
            }
            else if ch == ")" {
                throw NateError.message("替换格式包含未配对括号；字面括号需要反斜杠转义。")
            }
            else if ch == "\\", i < chars.count {
                let escape = chars[i]
                i += 1
                switch escape {
                case "L", "U": mode = String(escape)
                case "E": mode = ""
                case "l", "u": one = String(escape)
                case "n": append("\n")
                case "r": append("\r")
                case "t": append("\t")
                default:
                    if escape.isNumber {
                        var digits = String(escape)
                        while i < chars.count && chars[i].isNumber {
                            digits.append(chars[i])
                            i += 1
                        }
                        append(captured(Int(digits) ?? 0))
                    }
                    else {
                        append(String(escape))
                    }
                }
            }
            else if ch == "$", i < chars.count {
                let token = chars[i]
                i += 1
                if token == "$" {
                    append("$")
                }
                else if token == "&" {
                    append(captured(0))
                }
                else if token == "`" {
                    append(String(decoding: input[..<hit.utf16Range.location], as: UTF16.self))
                }
                else if token == "'" {
                    append(
                        String(
                            decoding: input[(hit.utf16Range.location + hit.utf16Range.length)...],
                            as: UTF16.self
                        )
                    )
                }
                else if token == "+", i < chars.count, chars[i] == "{" {
                    i += 1
                    let start = i
                    while i < chars.count && chars[i] != "}" {
                        i += 1
                    }
                    guard i < chars.count else {
                        throw NateError.message("替换捕获名称未闭合。")
                    }
                    let name = String(chars[start..<i])
                    i += 1
                    guard let id = hit.names[name] else {
                        throw NateError.message("替换中引用未知捕获 \(name)。")
                    }
                    append(captured(id))
                }
                else if token == "{" || token.isNumber {
                    var digits = token == "{" ? "" : String(token)
                    while i < chars.count && chars[i].isNumber {
                        digits.append(chars[i])
                        i += 1
                    }
                    if token == "{" {
                        guard i < chars.count, chars[i] == "}" else {
                            throw NateError.message("替换组号未闭合。")
                        }
                        i += 1
                    }
                    guard let id = Int(digits) else {
                        throw NateError.message("替换组号无效。")
                    }
                    append(captured(id))
                }
                else {
                    append("$" + String(token))
                }
            }
            else {
                append(String(ch))
            }
            guard result.utf8.count <= 64 * 1024 * 1024 else {
                throw NateError.message("单项替换输出超过 64 MB。")
            }
        }
        return result
    }

    /// 业务作用：保留嵌套与转义边界，读取完整的 Boost 替换分组。
    /// 参数说明:
    /// - chars: 原始格式字符。
    /// - index: 左括号后的解析位置，完成后位于右括号之后。
    /// 返回：分组内部原始格式；未闭合时失败。
    static func group(_ chars: [Character], index: inout Int) throws -> String {
        let start = index
        var nesting = 1
        while index < chars.count {
            let ch = chars[index]
            index += 1
            if ch == "\\" {
                index = min(chars.count, index + 1)
                continue
            }
            if ch == "(" {
                nesting += 1
            }
            if ch == ")" {
                nesting -= 1
            }
            guard nesting <= 128 else {
                throw NateError.message("替换分组超过 128 层。")
            }
            if nesting == 0 {
                return String(chars[start..<(index - 1)])
            }
        }
        throw NateError.message("替换分组未闭合。")
    }

    /// 业务作用：条件替换以捕获是否参与决定分支，而非判断捕获文字是否为空。
    /// 参数说明:
    /// - content: 分组内部格式。
    /// - hit: 原始命中的捕获证据。
    /// 返回：选中的原始分支格式，普通分组保持其内容。
    static func conditional(_ content: String, hit: SearchHit) throws -> String {
        guard content.first == "?" else {
            return content
        }
        let chars = Array(content)
        var index = 1
        let id: Int
        if index < chars.count && chars[index] == "{" {
            index += 1
            let start = index
            while index < chars.count && chars[index] != "}" {
                index += 1
            }
            guard index < chars.count, let found = hit.names[String(chars[start..<index])] else {
                throw NateError.message("条件替换捕获名称无效。")
            }
            id = found
            index += 1
        }
        else {
            let start = index
            while index < chars.count && chars[index].isNumber {
                index += 1
            }
            guard let found = Int(String(chars[start..<index])) else {
                throw NateError.message("条件替换缺少组号。")
            }
            id = found
        }
        let start = index
        var nesting = 0
        var divider: Int?
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\" {
                index += 2
                continue
            }
            if ch == "(" {
                nesting += 1
            }
            if ch == ")" {
                nesting -= 1
            }
            if ch == ":" && nesting == 0 {
                divider = index
                break
            }
            index += 1
        }
        if hit.captures[id] != nil {
            return String(chars[start..<(divider ?? chars.count)])
        }
        return divider.map {
            String(chars[($0 + 1)...])
        } ?? ""
    }
}
