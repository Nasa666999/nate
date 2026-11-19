import Foundation

public struct KeyboardShortcut: Sendable, Codable, Hashable {
    public let key: String
    public let modifiers: UInt8

    /// 业务作用：命令快捷键使用单个实际键和明确修饰键，不让普通输入字符变成隐式执行命令。
    /// 参数说明:
    /// - key: 单个 Unicode 标量对应的原生菜单键。
    /// - modifiers: Command、Option、Control、Shift 分别使用位 1、2、4、8。
    /// 返回：带 Command、Option 或 Control 的组合，或 F1 至 F35；支持 Tab、Return、Enter 和 Backspace 的修饰组合，其它控制键拒绝。
    public init(key: String, modifiers: UInt8) throws {
        guard key.utf8.count <= 4 else {
            throw NateError.message("快捷键不是单个实际键。")
        }
        let normalized = key == "\u{7F}" ? "\u{8}" : key.lowercased()
        guard normalized.unicodeScalars.count == 1, let scalar = normalized.unicodeScalars.first,
            (scalar.value >= 32 && scalar.value != 127 || [3, 8, 9, 13].contains(scalar.value)),
            modifiers <= 15,
            modifiers & 7 != 0 || (0xF704...0xF726).contains(scalar.value)
        else {
            throw NateError.message("快捷键需要单个键与 Command、Option 或 Control；功能键可单独使用。")
        }
        self.key = normalized
        self.modifiers = modifiers
    }

    /// 业务作用：恢复快捷键仍沿同一按键门禁，文件字段不能截获普通文字输入。
    /// 参数说明:
    /// - decoder: 所属配置提供的有界解码器。
    /// 返回：完整合法的快捷键；未知位或非法键拒绝。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: values.decode(String.self, forKey: .key),
            modifiers: values.decode(UInt8.self, forKey: .modifiers)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, modifiers
    }
}

public enum CompatibilityShortcut {
    /// 业务作用：编辑器分发和绑定冲突使用同一兼容按键规则，隐藏的 Control 入口不能被另一个命令截获。
    /// 参数说明:
    /// - key: 系统提供的未应用修饰文字键或功能键标量。
    /// - modifiers: 四个逻辑修饰键组成的位集合。
    /// 返回：既有兼容命令的稳定身份；不属于兼容入口时为空。
    public static func command(key: String, modifiers: UInt8) -> String? {
        guard key.utf8.count <= 4, modifiers <= 15, modifiers & 4 != 0 else {
            return nil
        }
        let key = key.lowercased()
        let previous = modifiers & 8 != 0
        let option = modifiers & 2 != 0
        if key == "\u{F706}" {
            return option
                ? (previous ? "volatileFindPrevious" : "volatileFindNext")
                : (previous ? "selectFindPrevious" : "selectFindNext")
        }
        if key == "\t" {
            return previous ? "previousTab" : "nextTab"
        }
        if key == "i", option {
            return "incrementalSearch"
        }
        if key == "b" {
            return option ? "selectBracketPair" : "matchingBracket"
        }
        return [
            "h": "replace",
            "f": "find",
            "s": "save",
            "n": "new",
            "o": "open",
            "w": "close",
            "g": "goto",
        ][key]
    }
}
