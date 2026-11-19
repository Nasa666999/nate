import Foundation

public enum CommandTemplate {
    /// 业务作用：只解释原始参数模板中的显式变量，替换值中的变量或 shell 字符不再执行第二次解释。
    /// 参数说明:
    /// - template: 单个原始参数，$$ 表示字面美元符。
    /// - values: 当前文档提供的可用变量，未命名文档不提供磁盘路径。
    /// 返回：完整数据参数；未知变量、缺失值或超过 1 MB 时失败。
    public static func expand(_ template: String, values: [String: String]) throws -> String {
        try transform(template) {
            key in
            guard let value = values[key] else {
                throw ExternalProcessFailure(reason: "命令变量 \(key) 没有可用值或不受支持；字面美元符请使用 $$。")
            }
            return value
        }
    }

    /// 业务作用：从原始模板提取真正引用的变量，转义美元符和替换值中的文字不产生隐式正文读取。
    /// 参数说明:
    /// - template: 尚未替换的单个完整程序、参数或工作目录模板。
    /// 返回：规范变量名集合；未知旧式别名、未闭合或超量模板拒绝，不执行内容。
    public static func referencedValues(in template: String) throws -> Set<String> {
        var referenced: Set<String> = []
        _ = try transform(template) {
            key in
            referenced.insert(key)
            return ""
        }
        return referenced
    }

    /// 业务作用：变量检查和展开使用同一个单次扫描，导入检查不能沿不同转义规则取得后续执行资格。
    /// 参数说明:
    /// - template: 当前原始模板。
    /// - resolve: 只解释当前模板中一个明确规范变量的取值方法。
    /// 返回：完整展开原文；非法别名、缺失值或容量不足拒绝。
    private static func transform(_ template: String, resolve: (String) throws -> String) throws -> String {
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
                    guard let key else {
                        throw ExternalProcessFailure(reason: "命令变量 \(name) 不受支持；字面美元符请使用 $$。")
                    }
                    let value = try resolve(key)
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
