import CryptoKit
import Foundation

public enum RunCommandArchive {
    public static let maximumBytes = 8 * 1_048_576

    /// 业务作用：完整命令库保存稳定身份、结构化模板与绑定，整份摘要保护字段和顺序。
    /// 参数说明:
    /// - library: 已通过完整名称、身份、绑定和内存门禁的命令库。
    /// - permit: 本次完整编码仍有效的资格。
    /// 返回：最多 8 MiB 的完整归档；超量或取消不提供部分配置。
    public static func encode(
        _ library: RunCommandLibrary,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = RunCommandArchiveBudget(permit: permit)
        var writer = RunCommandArchiveWriter(budget: budget)
        try writer.append(Data("NATERUNS".utf8))
        try writer.unsigned(UInt16(1))
        try writer.unsigned(UInt16(library.commands.count))
        for command in library.commands {
            try writer.append(
                withUnsafeBytes(of: command.id.uuid) {
                    Data($0)
                }
            )
            try writer.unsigned(UInt16(command.name.utf8.count))
            try writer.append(Data(command.name.utf8))
            try writer.text(command.executable)
            try writer.unsigned(UInt16(command.arguments.count))
            for argument in command.arguments {
                try writer.text(argument)
            }
            try writer.unsigned(UInt8(command.directory == nil ? 0 : 1))
            if let directory = command.directory {
                try writer.text(directory)
            }
            try writer.unsigned(UInt8(command.shortcut == nil ? 0 : 1))
            if let shortcut = command.shortcut {
                try writer.unsigned(UInt8(shortcut.key.utf8.count))
                try writer.append(Data(shortcut.key.utf8))
                try writer.unsigned(shortcut.modifiers)
            }
        }
        try budget.check()
        let digest = Data(SHA256.hash(data: writer.data))
        try writer.append(digest)
        return writer.data
    }

    /// 业务作用：整份摘要、字段和模型全部通过后才恢复命令库，读取本身从不授予执行权。
    /// 参数说明:
    /// - data: 同一次有界读取取得的完整归档。
    /// - permit: 解析仍属于当前请求的资格。
    /// 返回：完整合法命令库；损坏、未知、重复、超量或取消均保留原文件。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> RunCommandLibrary {
        let budget = RunCommandArchiveBudget(permit: permit)
        try budget.check()
        guard (44...maximumBytes).contains(data.count) else {
            throw NateError.message("运行配置归档长度无效或超过 8 MiB。")
        }
        let body = Data(data.dropLast(32))
        let digest = Data(SHA256.hash(data: body))
        try budget.check()
        guard digest.elementsEqual(data.suffix(32)) else {
            throw NateError.message("运行配置摘要不一致，原文件保留。")
        }
        var reader = RunCommandArchiveReader(data: body, budget: budget)
        guard try reader.bytes(8) == Data("NATERUNS".utf8), try reader.unsigned(UInt16.self) == 1 else {
            throw RunCommandArchiveError.unsupportedFormat
        }
        let count = Int(try reader.unsigned(UInt16.self))
        guard count <= RunCommandLibrary.maximumCommands else {
            throw NateError.message("命名运行配置超过二百五十六项。")
        }
        var commands: [NamedRunCommand] = []
        var retained = 0
        for _ in 0..<count {
            let bytes = [UInt8](try reader.bytes(16))
            let id = UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
            let nameSize = Int(try reader.unsigned(UInt16.self))
            guard nameSize <= 512, let name = UTF8Text.decode(try reader.bytes(nameSize)) else {
                throw NateError.message("运行配置名称超量或不是合法 UTF-8。")
            }
            let executable = try reader.text()
            let argumentCount = Int(try reader.unsigned(UInt16.self))
            guard argumentCount <= NamedRunCommand.maximumArguments else {
                throw NateError.message("运行配置参数超过一千零二十四项。")
            }
            var arguments: [String] = []
            var templateBytes = executable.utf8.count
            for _ in 0..<argumentCount {
                let argument = try reader.text()
                guard argument.utf8.count <= NamedRunCommand.maximumTemplateBytes - templateBytes else {
                    throw NateError.message("运行配置完整模板超过 4 MiB。")
                }
                templateBytes += argument.utf8.count
                arguments.append(argument)
            }
            let hasDirectory = try reader.unsigned(UInt8.self)
            guard hasDirectory <= 1 else {
                throw RunCommandArchiveError.unsupportedFormat
            }
            let directory = hasDirectory == 1 ? try reader.text() : nil
            let hasShortcut = try reader.unsigned(UInt8.self)
            guard hasShortcut <= 1 else {
                throw RunCommandArchiveError.unsupportedFormat
            }
            var shortcut: KeyboardShortcut?
            if hasShortcut == 1 {
                let size = Int(try reader.unsigned(UInt8.self))
                guard size <= 4, let key = UTF8Text.decode(try reader.bytes(size)) else {
                    throw NateError.invalidText
                }
                let value = try KeyboardShortcut(key: key, modifiers: reader.unsigned(UInt8.self))
                guard key.utf8.elementsEqual(value.key.utf8) else {
                    throw RunCommandArchiveError.unsupportedFormat
                }
                shortcut = value
            }
            let command = try NamedRunCommand(
                id: id,
                name: name,
                executable: executable,
                arguments: arguments,
                directory: directory,
                shortcut: shortcut
            )
            guard command.retainedBytes <= RunCommandLibrary.maximumRetainedBytes - retained else {
                throw NateError.message("运行配置估计保留容量超过 16 MiB。")
            }
            retained += command.retainedBytes
            commands.append(command)
        }
        guard reader.cursor == body.count else {
            throw RunCommandArchiveError.unsupportedFormat
        }
        try budget.check()
        return try RunCommandLibrary(commands)
    }
}
