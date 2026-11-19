import AppKit
import NateCore

@MainActor
public enum NativeKeyboardShortcut {
    /// 业务作用：快捷键显示明确的方向与功能键名称，私有功能键标量不直接变成不可辨认字形。
    /// 参数说明:
    /// - value: 当前完整绑定，无绑定时为空。
    /// 返回：四个修饰键、功能键或实际普通键的可读名称。
    public static func label(_ value: KeyboardShortcut?) -> String {
        guard let value else {
            return "点击录制快捷键"
        }
        var result = ""
        for (bit, symbol) in [(UInt8(4), "⌃"), (UInt8(2), "⌥"), (UInt8(8), "⇧"), (UInt8(1), "⌘")] {
            if value.modifiers & bit != 0 {
                result += symbol
            }
        }
        if let scalar = value.key.unicodeScalars.first {
            if (0xF704...0xF726).contains(scalar.value) {
                return result + "F\(scalar.value - 0xF704 + 1)"
            }
            let names: [UInt32: String] = [
                UInt32(NSUpArrowFunctionKey): "↑",
                UInt32(NSDownArrowFunctionKey): "↓",
                UInt32(NSLeftArrowFunctionKey): "←",
                UInt32(NSRightArrowFunctionKey): "→",
                UInt32(NSInsertFunctionKey): "Insert",
                UInt32(NSDeleteFunctionKey): "⌦",
                UInt32(NSHomeFunctionKey): "Home",
                UInt32(NSEndFunctionKey): "End",
                UInt32(NSPageUpFunctionKey): "Page Up",
                UInt32(NSPageDownFunctionKey): "Page Down",
                UInt32(NSClearLineFunctionKey): "Clear",
                UInt32(NSHelpFunctionKey): "Help",
            ]
            if let name = names[scalar.value] {
                return result + name
            }
        }
        return result + (value.key == " " ? "Space" : value.key.uppercased())
    }

    /// 业务作用：设备、数字键盘和功能标记不成为命令组合身份，按键捕获与菜单比较使用同一修饰集合。
    /// 参数说明:
    /// - flags: 当前 AppKit 事件或菜单修饰键。
    /// 返回：Command、Option、Control、Shift 对应的四个位。
    public static func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        (flags.contains(.command) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.control) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    /// 业务作用：已验证的逻辑按键恢复为原生菜单组合，不额外增加设备相关修饰位。
    /// 参数说明:
    /// - shortcut: 完整逻辑组合。
    /// 返回：用于 AppKit 菜单的四个修饰键集合。
    public static func modifiers(_ shortcut: KeyboardShortcut) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        for (bit, flag) in [
            (UInt8(1), NSEvent.ModifierFlags.command), (UInt8(2), .option), (UInt8(4), .control),
            (UInt8(8), .shift),
        ] {
            if shortcut.modifiers & bit != 0 {
                result.insert(flag)
            }
        }
        return result
    }

    /// 业务作用：菜单大写字母包含隐式 Shift，冲突检查不能把 Command-V 与 Command-Shift-V 混为一项。
    /// 参数说明:
    /// - key: 原生菜单的实际 keyEquivalent。
    /// - modifiers: 菜单明确登记的修饰键。
    /// 返回：可配置的完整逻辑组合；无按键或不受支持的原生键为空。
    public static func menu(key: String, modifiers: NSEvent.ModifierFlags) -> KeyboardShortcut? {
        var bits = modifierBits(modifiers)
        if !key.utf8.elementsEqual(key.lowercased().utf8) {
            bits |= 8
        }
        return try? KeyboardShortcut(key: key, modifiers: bits)
    }

    /// 业务作用：明确捕获只读取未应用修饰的原键和实际修饰状态，不把 Shift 形成的文字重复算成另一个键。
    /// 参数说明:
    /// - event: 当前捕获控件拥有的真实键盘事件。
    /// 返回：完整合法组合；系统没有可用键值时为空，非法组合给出原因。
    public static func capture(_ event: NSEvent) throws -> KeyboardShortcut? {
        guard let key = event.characters(byApplyingModifiers: []), !key.isEmpty else {
            return nil
        }
        return try KeyboardShortcut(key: key, modifiers: modifierBits(event.modifierFlags))
    }
}
