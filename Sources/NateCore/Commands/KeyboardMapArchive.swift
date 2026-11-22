import CryptoKit
import Foundation

public enum KeyboardMapArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat

    public var errorDescription: String? {
        "快捷键映射包含不受支持的格式或字段，原配置保留。"
    }
}

public enum KeyboardMapArchive {
    public static let maximumBytes = 1_048_576
    private static let magic = Data("NATEKEYS".utf8)

    /// 业务作用：映射保存完整命令身份和有序组合，整份归档校验与容量门禁先于任何文件覆盖。
    /// 参数说明:
    /// - configuration: 已完整校验的用户覆盖。
    /// - permit: 本次编码仍有资格，取消时不提供部分归档。
    /// 返回：不超过 1 MiB 且包含 SHA-256 的完整归档；超量、超时或取消失败。
    public static func encode(
        _ configuration: KeyboardMap,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = KeyboardMapBudget(permit: permit)
        try budget.check()
        var data = magic
        append(UInt16(1), to: &data)
        append(UInt16(configuration.overrides.count), to: &data)
        for binding in configuration.overrides {
            try budget.check()
            let cost =
                3 + binding.command.utf8.count
                + binding.shortcuts.reduce(0) {
                    $0 + 2 + $1.key.utf8.count
                }
            guard cost <= maximumBytes - data.count - 32 else {
                throw NateError.message("快捷键映射超过 1 MiB，原文件保留。")
            }
            append(UInt16(binding.command.utf8.count), to: &data)
            data.append(contentsOf: binding.command.utf8)
            data.append(UInt8(binding.shortcuts.count))
            for shortcut in binding.shortcuts {
                data.append(UInt8(shortcut.key.utf8.count))
                data.append(contentsOf: shortcut.key.utf8)
                data.append(shortcut.modifiers)
            }
        }
        try budget.check()
        let digest = Data(SHA256.hash(data: data))
        data.append(digest)
        try budget.check()
        return data
    }

    /// 业务作用：导入只接受完整、规范且受支持的绑定，不忽略未来字段后重新解释命令。
    /// 参数说明:
    /// - data: 最多 1 MiB 的原始归档。
    /// - permit: 本次完整读取仍有执行资格。
    /// 返回：全部有序覆盖；摘要、UTF-8、数量、命令或按键无效时不提供部分配置。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> KeyboardMap {
        let budget = KeyboardMapBudget(permit: permit)
        try budget.check()
        guard data.count <= maximumBytes, data.count >= 44, data.starts(with: magic) else {
            throw NateError.message("快捷键映射大小或文件头无效，原配置保留。")
        }
        let body = Data(data.dropLast(32))
        guard Data(SHA256.hash(data: body)).elementsEqual(data.suffix(32)) else {
            throw NateError.message("快捷键映射摘要不一致，原配置保留。")
        }
        var reader = KeyboardMapReader(data: body, budget: budget)
        _ = try reader.bytes(8)
        guard try reader.u16() == 1 else {
            throw KeyboardMapArchiveError.unsupportedFormat
        }
        let count = Int(try reader.u16())
        guard count <= KeyboardMap.maximumCommands else {
            throw NateError.message("快捷键映射超过两千项命令。")
        }
        var bindings: [CommandKeyBinding] = []
        for _ in 0..<count {
            let size = Int(try reader.u16())
            guard (1...KeyboardMap.maximumCommandBytes).contains(size),
                let command = UTF8Text.decode(try reader.bytes(size))
            else {
                throw KeyboardMapArchiveError.unsupportedFormat
            }
            let keyCount = Int(try reader.u8())
            guard keyCount <= KeyboardMap.maximumBindingsPerCommand else {
                throw NateError.message("同一命令的快捷键超过十六项。")
            }
            var shortcuts: [KeyboardShortcut] = []
            for _ in 0..<keyCount {
                let size = Int(try reader.u8())
                guard (1...4).contains(size), let key = UTF8Text.decode(try reader.bytes(size))
                else {
                    throw KeyboardMapArchiveError.unsupportedFormat
                }
                let shortcut = try KeyboardShortcut(key: key, modifiers: reader.u8())
                guard shortcut.key.utf8.elementsEqual(key.utf8) else {
                    throw NateError.message("快捷键映射包含非规范按键身份，原配置保留。")
                }
                shortcuts.append(shortcut)
            }
            bindings.append(try CommandKeyBinding(command: command, shortcuts: shortcuts))
        }
        guard reader.cursor == body.count else {
            throw KeyboardMapArchiveError.unsupportedFormat
        }
        let configuration = try KeyboardMap(bindings)
        try budget.check()
        return configuration
    }

    /// 业务作用：固定计数与长度采用小端无符号字段，归档不依赖主机位宽或内存对齐。
    /// 参数说明:
    /// - value: 已校验在协议字段内的计数或长度。
    /// - data: 当前完整归档缓冲区。
    /// 返回：完整追加两个字节，不改变字段含义。
    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
}

private struct KeyboardMapBudget {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let permit: @Sendable () -> Bool

    /// 业务作用：整份映射编解码共用五秒截止与取消资格，不能依靠大量小字段重复取得预算。
    /// 参数说明: 无。
    /// 返回：本轮仍有效时继续，取消或超时整体失败。
    func check() throws {
        try Task.checkCancellation()
        guard permit() else {
            throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
            throw NateError.message("快捷键映射处理超过五秒，原配置保留。")
        }
    }
}

private struct KeyboardMapReader {
    let data: Data
    let budget: KeyboardMapBudget
    var cursor = 0

    /// 业务作用：字段声明只允许消耗已取得的同份归档，不授予额外分配或越界访问资格。
    /// 参数说明:
    /// - count: 当前完整字段的字节数。
    /// 返回：完整原字节；截断、非法长度、取消或超时拒绝。
    mutating func bytes(_ count: Int) throws -> Data {
        try budget.check()
        guard count >= 0, count <= data.count - cursor else {
            throw NateError.message("快捷键映射在字段中截断。")
        }
        let start = data.startIndex + cursor
        cursor += count
        return Data(data[start..<(start + count)])
    }

    /// 业务作用：逐字节读取键数量与修饰位，截断归档不能被解释为零值。
    /// 参数说明: 无。
    /// 返回：完整的一字节字段；缺失或取消时失败。
    mutating func u8() throws -> UInt8 {
        let field = try bytes(1)
        return field[field.startIndex]
    }

    /// 业务作用：完整读取小端计数和长度，不使用未对齐的原始内存转换。
    /// 参数说明: 无。
    /// 返回：完整两字节字段；缺失或取消时失败。
    mutating func u16() throws -> UInt16 {
        let field = try bytes(2)
        return UInt16(field[field.startIndex]) | UInt16(field[field.startIndex + 1]) << 8
    }
}
