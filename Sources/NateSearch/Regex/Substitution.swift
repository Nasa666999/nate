import Foundation
import NateCore

enum Substitution {
    /// 业务作用：解释 Boost 风格捕获、上下文与大小写替换，空替换合法。
    /// 参数说明:
    /// - format: 用户替换表达式。
    /// - hit: 已参与捕获与命名映射。
    /// - input: 原快照 UTF-16 上下文。
    /// 返回：完整替换文字；格式错误在提交前失败。
    static func expand(_ format: String, hit: SearchHit, input: [UInt16]) throws -> String {
        let chars = Array(format)
        var i = 0
        var result = ""
        var mode = ""
        var one = ""
        func captured(_ id: Int) -> String {
            guard let r = hit.captures[id], r.location >= 0, r.location + r.length <= input.count else {
                return ""
            }
            return String(decoding: input[r.location..<(r.location + r.length)], as: UTF16.self)
        }
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
            if ch == "\\", i < chars.count {
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
}
