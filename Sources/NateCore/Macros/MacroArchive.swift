import CryptoKit
import Foundation

public enum MacroArchive {
    public static let maximumBytes = 8_388_608
    public static let maximumActions = 10_000
    static let magic = Data("NATEMACR".utf8)

    /// 业务作用：完整宏使用有界二进制归档保存原始文字、排序参数与剪贴板形态，保存预算与载入一致。
    /// 参数说明:
    /// - actions: 按实际执行顺序排列的全部语义动作。
    /// - permit: 本次完整归档仍有执行资格。
    /// 返回：含整份 SHA-256 的不超过 8 MiB 归档；未知动作、超量或取消不提供部分配置。
    public static func encode(
        _ actions: [MacroAction],
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = MacroArchiveBudget(permit: permit)
        try budget.check()
        guard actions.count <= maximumActions else {
            throw NateError.message("宏动作超过一万项。")
        }
        var writer = MacroArchiveWriter(budget: budget)
        try writer.append(magic)
        writer.unsigned(UInt16(1))
        writer.unsigned(UInt32(actions.count))
        for action in actions {
            try budget.check()
            try action.validateSupport()
            switch action {
            case .search(let search):
                guard
                    search.options.query.utf8.count + search.options.replacement.utf8.count <= maximumBytes
                        - writer.data.count - 37
                else {
                    throw NateError.message("宏搜索原文与归档索引超过 8 MiB。")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(search)
                writer.unsigned(UInt8(5))
                writer.unsigned(UInt32(data.count))
                try writer.append(data)
            case .input(let text):
                guard text.utf8.count <= maximumBytes - writer.data.count - 37 else {
                    throw NateError.message("宏输入与归档索引超过 8 MiB。")
                }
                writer.unsigned(UInt8(0))
                writer.unsigned(UInt32(text.utf8.count))
                try writer.append(Data(text.utf8))
            case .command(let name):
                writer.unsigned(UInt8(1))
                writer.unsigned(UInt16(name.utf8.count))
                try writer.append(Data(name.utf8))
            case .editor(let command):
                writer.unsigned(UInt8(4))
                writer.unsigned(UInt16(command.rawValue.utf8.count))
                try writer.append(Data(command.rawValue.utf8))
            case .lineSort(let options):
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(options)
                writer.unsigned(UInt8(2))
                writer.unsigned(UInt32(data.count))
                try writer.append(data)
            case .clipboard(let payload, let adapting):
                var size = 20
                if case .rectangle = payload.shape {
                    size += 17
                }
                for fragment in payload.fragments {
                    try budget.check()
                    guard fragment.text.utf8.count <= maximumBytes - size - 17 else {
                        throw NateError.message("宏剪贴板载荷超过归档容量。")
                    }
                    size += 17 + fragment.text.utf8.count
                }
                // 在建立剪贴板编码之前确认整份宏仍有空间，避免先复制大载荷再发现后续无法保存。
                guard size <= maximumBytes - writer.data.count - 38 else {
                    throw NateError.message("宏剪贴板及归档索引超过 8 MiB。")
                }
                let data = try payload.encoded(deadline: budget.deadline, permit: permit)
                writer.unsigned(UInt8(3))
                writer.unsigned(UInt8(adapting ? 1 : 0))
                writer.unsigned(UInt32(data.count))
                try writer.append(data)
            }
        }
        try budget.check()
        let digest = Data(SHA256.hash(data: writer.data))
        try writer.append(digest)
        return writer.data
    }

    /// 业务作用：宏载入只接受完整受支持动作，二进制摘要与旧式 JSON 均在任何正文修改前验证。
    /// 参数说明:
    /// - data: 用户选择的完整文件，最多 8 MiB。
    /// - permit: 当前仍有完整载入资格。
    /// 返回：全部有效动作的原顺序；未知格式、截断、非法 UTF-8、超量或取消时保留原宏。
    public static func decode(
        _ data: Data,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> [MacroAction] {
        let budget = MacroArchiveBudget(permit: permit)
        try budget.check()
        guard data.count <= maximumBytes else {
            throw NateError.message("宏文件超过 8 MiB。")
        }
        guard data.starts(with: magic) else {
            return try decodeLegacy(data, budget: budget)
        }
        guard data.count >= 46 else {
            throw NateError.message("宏归档已经截断。")
        }
        let body = Data(data.dropLast(32))
        let digest = Data(SHA256.hash(data: body))
        try budget.check()
        guard digest.elementsEqual(data.suffix(32)) else {
            throw NateError.message("宏归档摘要不一致，原配置保留。")
        }
        var reader = MacroArchiveReader(data: body, budget: budget)
        _ = try reader.bytes(8)
        guard try reader.unsigned(UInt16.self) == 1 else {
            throw MacroArchiveError.unsupportedFormat
        }
        let count = Int(try reader.unsigned(UInt32.self))
        guard count <= maximumActions else {
            throw NateError.message("宏动作超过一万项。")
        }
        var actions: [MacroAction] = []
        for _ in 0..<count {
            try budget.check()
            let action: MacroAction
            switch try reader.unsigned(UInt8.self) {
            case 5:
                let size = Int(try reader.unsigned(UInt32.self))
                let bytes = try reader.bytes(size)
                try validateSearchObject(JSONSerialization.jsonObject(with: bytes))
                action = .search(try JSONDecoder().decode(MacroSearchAction.self, from: bytes))
            case 0:
                let size = Int(try reader.unsigned(UInt32.self))
                let bytes = try reader.bytes(size)
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw NateError.message("宏输入包含非法 UTF-8。")
                }
                action = .input(text)
            case 1:
                let size = Int(try reader.unsigned(UInt16.self))
                let bytes = try reader.bytes(size)
                guard let name = String(data: bytes, encoding: .utf8) else {
                    throw NateError.message("宏命令名称包含非法 UTF-8。")
                }
                action = .command(name)
            case 2:
                let size = Int(try reader.unsigned(UInt32.self))
                guard size <= 8192 else {
                    throw NateError.message("宏排序参数超过 8 KiB。")
                }
                let bytes = try reader.bytes(size)
                try validateSortObject(JSONSerialization.jsonObject(with: bytes))
                action = .lineSort(try JSONDecoder().decode(LineSortOptions.self, from: bytes))
            case 4:
                let size = Int(try reader.unsigned(UInt16.self))
                let bytes = try reader.bytes(size)
                guard let name = String(data: bytes, encoding: .utf8),
                    let command = EditorCommand(rawValue: name)
                else {
                    throw MacroArchiveError.unsupportedFormat
                }
                action = .editor(command)
            case 3:
                let adapting = try reader.unsigned(UInt8.self)
                guard adapting <= 1 else {
                    throw MacroArchiveError.unsupportedFormat
                }
                let size = Int(try reader.unsigned(UInt32.self))
                let bytes = try reader.bytes(size)
                action = .clipboard(
                    try ClipboardPayload.decode(bytes, deadline: budget.deadline, permit: permit),
                    adaptLineEndings: adapting == 1
                )
            default:
                throw MacroArchiveError.unsupportedFormat
            }
            try action.validateSupport()
            actions.append(action)
        }
        guard reader.cursor == body.count else {
            throw MacroArchiveError.unsupportedFormat
        }
        try budget.check()
        return actions
    }

    /// 业务作用：旧式 JSON 宏仍完整读取，但未知动作包装字段不能在解码时被丢弃。
    /// 参数说明:
    /// - data: 已通过文件大小门禁的原始 JSON。
    /// - budget: 整份宏的共同执行预算。
    /// 返回：全部明确支持的动作；数量、字段或语义无效时整体失败。
    private static func decodeLegacy(_ data: Data, budget: MacroArchiveBudget) throws -> [MacroAction] {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            objects.count <= maximumActions
        else {
            throw NateError.message("宏格式不是完整动作列表，或动作超过一万项。")
        }
        var actions: [MacroAction] = []
        for object in objects {
            try budget.check()
            guard object.count == 1, let (kind, value) = object.first,
                let fields = value as? [String: Any]
            else {
                throw MacroArchiveError.unsupportedFormat
            }
            let action: MacroAction
            switch kind {
            case "search":
                guard Set(fields.keys) == ["_0"], let search = fields["_0"] else {
                    throw MacroArchiveError.unsupportedFormat
                }
                try validateSearchObject(search)
                let bytes = try JSONSerialization.data(withJSONObject: search)
                action = .search(try JSONDecoder().decode(MacroSearchAction.self, from: bytes))
            case "input", "command":
                guard Set(fields.keys) == ["_0"] else {
                    throw MacroArchiveError.unsupportedFormat
                }
                guard let text = fields["_0"] as? String else {
                    throw NateError.message("宏文字字段不是完整字符串。")
                }
                action = kind == "input" ? .input(text) : .command(text)
            case "lineSort":
                guard Set(fields.keys) == ["_0"], let options = fields["_0"] else {
                    throw MacroArchiveError.unsupportedFormat
                }
                try validateSortObject(options)
                let bytes = try JSONSerialization.data(withJSONObject: options)
                action = .lineSort(try JSONDecoder().decode(LineSortOptions.self, from: bytes))
            case "editor":
                guard Set(fields.keys) == ["_0"], let name = fields["_0"] as? String,
                    let command = EditorCommand(rawValue: name)
                else {
                    throw MacroArchiveError.unsupportedFormat
                }
                action = .editor(command)
            case "clipboard":
                guard Set(fields.keys) == ["_0", "adaptLineEndings"] else {
                    throw MacroArchiveError.unsupportedFormat
                }
                let bytes = try JSONSerialization.data(withJSONObject: fields)
                let source = try JSONDecoder().decode(LegacyMacroClipboard.self, from: bytes)
                action = .clipboard(
                    try ClipboardPayload.decode(source._0, deadline: budget.deadline, permit: budget.permit),
                    adaptLineEndings: source.adaptLineEndings
                )
            default:
                throw MacroArchiveError.unsupportedFormat
            }
            try budget.check()
            try action.validateSupport()
            actions.append(action)
        }
        try budget.check()
        return actions
    }

    /// 业务作用：完整搜索状态不能忽略未来字段后按另一种表达式、范围或替换策略执行。
    /// 参数说明:
    /// - object: 从有界归档读取的单个搜索动作对象。
    /// 返回：包装及全部当前选项字段明确且完整时继续，其它格式拒绝。
    private static func validateSearchObject(_ object: Any) throws {
        guard let fields = object as? [String: Any],
            Set(fields.keys) == ["command", "options", "stayAfterReplace"],
            let options = fields["options"] as? [String: Any],
            Set(options.keys) == [
                "query", "replacement", "mode", "caseSensitive", "wholeWord", "dotMatchesNewline",
                "wrap", "backwards", "selectionOnly", "recursive", "includeHidden", "ignoreOpenBuffers",
                "maxMatches", "stepLimit",
            ]
        else {
            throw MacroArchiveError.unsupportedFormat
        }
    }

    /// 业务作用：排序参数必须完整保留当前三个公开字段，不能忽略未来字段后按另一种键解释宏。
    /// 参数说明:
    /// - object: 从有界原始 JSON 取得的单个排序对象。
    /// 返回：字段集合明确且完整时继续，其它格式拒绝。
    private static func validateSortObject(_ object: Any) throws {
        guard let fields = object as? [String: Any],
            Set(fields.keys) == ["kind", "descending", "localeIdentifier"]
        else {
            throw MacroArchiveError.unsupportedFormat
        }
    }
}

private struct LegacyMacroClipboard: Decodable {
    let _0: Data
    let adaptLineEndings: Bool
}
