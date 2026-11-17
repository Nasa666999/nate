import Foundation

public enum CommandTemplate {
    /// 业务作用：只解释原始参数模板中的显式变量，替换值中的变量或 shell 字符不再执行第二次解释。
    /// 参数说明:
    /// - template: 单个原始参数，$$ 表示字面美元符。
    /// - values: 当前文档提供的可用变量，未命名文档不提供磁盘路径。
    /// 返回：完整数据参数；未知变量、缺失值或超过 1 MB 时失败。
    public static func expand(_ template: String, values: [String: String]) throws -> String {
        guard template.utf8.count <= 1_048_576 else {
            throw ExternalProcessFailure(reason: "命令参数模板超过 1 MB。")
        }
        let bytes = Array(template.utf8)
        let aliases = [
            "FULL_CURRENT_PATH": "file", "CURRENT_DIRECTORY": "directory", "FILE_NAME": "name",
            "NAME_PART": "stem", "EXT_PART": "extension", "CURRENT_SELECTED_TEXT": "selection",
            "CURRENT_WORD": "word", "CURRENT_LINESTR": "lineText", "CURRENT_LINE": "line",
            "CURRENT_COLUMN": "column",
        ]
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 36, index + 1 < bytes.count {
                let next = bytes[index + 1]
                if next == 36 {
                    guard output.count < 1_048_576 else {
                        throw ExternalProcessFailure(reason: "命令参数展开超过 1 MB。")
                    }
                    output.append(36)
                    index += 2
                    continue
                }
                if next == 123 || next == 40 {
                    let closing: UInt8 = next == 123 ? 125 : 41
                    let start = index + 2
                    guard let end = bytes[start...].firstIndex(of: closing) else {
                        throw ExternalProcessFailure(reason: "命令参数变量没有闭合。")
                    }
                    let name = String(decoding: bytes[start..<end], as: UTF8.self)
                    let key = next == 40 ? aliases[name] : name
                    guard let key, let value = values[key] else {
                        throw ExternalProcessFailure(reason: "命令变量 \(name) 没有可用值或不受支持；字面美元符请使用 $$。")
                    }
                    guard value.utf8.count <= 1_048_576 - output.count else {
                        throw ExternalProcessFailure(reason: "命令参数展开超过 1 MB。")
                    }
                    output.append(contentsOf: value.utf8)
                    index = end + 1
                    continue
                }
            }
            guard output.count < 1_048_576 else {
                throw ExternalProcessFailure(reason: "命令参数展开超过 1 MB。")
            }
            output.append(bytes[index])
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }
}
