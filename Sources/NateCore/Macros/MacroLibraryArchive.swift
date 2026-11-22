import CryptoKit
import Foundation

public enum MacroLibraryArchive {
    public static let maximumBytes = 16 * 1024 * 1024

    /// 业务作用：完整命名宏库保存身份、名称、快捷键和各自归档，整份摘要保护执行顺序与绑定关系。
    /// 参数说明:
    /// - snapshot: 已通过数量、内存与冲突门禁的完整库。
    /// - permit: 本次归档仍有执行资格。
    /// 返回：不超过 16 MiB 的完整归档；容量、取消或超时失败不返回部分库。
    public static func encode(
        _ snapshot: MacroLibrarySnapshot,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = MacroArchiveBudget(permit: permit)
        var writer = MacroArchiveWriter(budget: budget, maximumBytes: maximumBytes)
        try writer.append(Data("NATELIBR".utf8))
        writer.unsigned(UInt16(1))
        writer.unsigned(UInt16(snapshot.definitions.count))
        for definition in snapshot.definitions {
            try budget.check()
            try writer.append(
                withUnsafeBytes(of: definition.id.uuid) {
                    Data($0)
                }
            )
            writer.unsigned(UInt16(definition.name.utf8.count))
            try writer.append(Data(definition.name.utf8))
            writer.unsigned(UInt8(definition.shortcut == nil ? 0 : 1))
            if let shortcut = definition.shortcut {
                writer.unsigned(UInt8(shortcut.key.utf8.count))
                try writer.append(Data(shortcut.key.utf8))
                writer.unsigned(shortcut.modifiers)
            }
            writer.unsigned(UInt32(definition.archive.count))
            try writer.append(definition.archive)
        }
        try budget.check()
        let digest = Data(SHA256.hash(data: writer.data))
        try writer.append(digest)
        return writer.data
    }

    /// 业务作用：恢复宏库先核对整份摘要，再完整解码每个宏，未知字段或重复绑定不能取得播放资格。
    /// 参数说明:
    /// - data: 同一次有界读取取得的完整归档。
    /// - permit: 当前仍有完整恢复资格。
    /// 返回：全部定义合法且无冲突的库；未知、损坏、超量或取消时保留原文件。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> MacroLibrarySnapshot {
        let budget = MacroArchiveBudget(permit: permit)
        try budget.check()
        guard (44...maximumBytes).contains(data.count) else {
            throw NateError.message("宏库归档长度无效或超过 16 MiB。")
        }
        let body = Data(data.dropLast(32))
        let digest = Data(SHA256.hash(data: body))
        try budget.check()
        guard digest.elementsEqual(data.suffix(32)) else {
            throw NateError.message("宏库摘要不一致，原文件保留。")
        }
        var reader = MacroArchiveReader(data: body, budget: budget)
        guard try reader.bytes(8) == Data("NATELIBR".utf8), try reader.unsigned(UInt16.self) == 1 else {
            throw MacroArchiveError.unsupportedFormat
        }
        let count = Int(try reader.unsigned(UInt16.self))
        guard count <= MacroLibrarySnapshot.maximumDefinitions else {
            throw NateError.message("宏库超过一千项。")
        }
        let allowed: @Sendable () -> Bool = {
            permit() && .now < budget.deadline
        }
        var definitions: [NamedMacro] = []
        var identities: Set<UUID> = []
        var names: Set<String> = []
        var shortcuts: Set<MacroShortcut> = []
        var retained = 0
        for _ in 0..<count {
            try budget.check()
            let bytes = [UInt8](try reader.bytes(16))
            let id = UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                    bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
            guard identities.insert(id).inserted else {
                throw NateError.message("宏库包含重复身份。")
            }
            let nameSize = Int(try reader.unsigned(UInt16.self))
            guard nameSize <= 512 else {
                throw NateError.message("宏名称超过 512 字节。")
            }
            guard let name = UTF8Text.decode(try reader.bytes(nameSize)) else {
                throw NateError.invalidText
            }
            guard names.insert(name).inserted else {
                throw NateError.message("宏库包含重复名称。")
            }
            let bound = try reader.unsigned(UInt8.self)
            guard bound <= 1 else {
                throw MacroArchiveError.unsupportedFormat
            }
            let shortcut: MacroShortcut?
            if bound == 1 {
                let size = Int(try reader.unsigned(UInt8.self))
                guard size <= 4, let key = UTF8Text.decode(try reader.bytes(size)) else {
                    throw NateError.invalidText
                }
                let value = try MacroShortcut(key: key, modifiers: reader.unsigned(UInt8.self))
                shortcut = value
                guard shortcuts.insert(value).inserted else {
                    throw NateError.message("宏库包含重复快捷键。")
                }
            }
            else {
                shortcut = nil
            }
            let size = Int(try reader.unsigned(UInt32.self))
            guard size <= MacroArchive.maximumBytes else {
                throw NateError.message("库内宏归档超过 8 MiB。")
            }
            let definition = try NamedMacro(
                id: id,
                name: name,
                archive: reader.bytes(size),
                shortcut: shortcut,
                permit: allowed
            )
            guard definition.retainedBytes <= MacroLibrarySnapshot.maximumRetainedBytes - retained else {
                throw NateError.message("宏库动作与归档的估计保留容量超过 64 MiB。")
            }
            retained += definition.retainedBytes
            definitions.append(definition)
        }
        guard reader.cursor == body.count else {
            throw MacroArchiveError.unsupportedFormat
        }
        try budget.check()
        return try MacroLibrarySnapshot(definitions)
    }
}
