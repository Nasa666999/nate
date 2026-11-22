import Foundation

extension ClipboardPayload {
    /// 业务作用：生成带明确格式身份的私有剪贴板数据，NUL、Unicode 原文和空行不依赖文本转义。
    /// 参数说明:
    /// - deadline: 整个复制或配置保存的共同截止。
    /// - permit: 当前仍可继续编码并发布。
    /// 返回：完整小端二进制载荷；取消、超时或超过 96 MiB 时失败。
    public func encoded(
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> Data {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        var writer = ClipboardBinaryWriter(budget: budget)
        writer.data.reserveCapacity(
            min(ClipboardLimits.encodedBytes, plainByteCount + fragments.count * 32 + 64)
        )
        try writer.append(Data("NATECLIP".utf8))
        writer.unsigned(UInt16(1))
        switch shape {
        case .stream: writer.unsigned(UInt8(0))
        case .lines: writer.unsigned(UInt8(1))
        case .rectangle: writer.unsigned(UInt8(2))
        }
        switch lineEnding {
        case .lf: writer.unsigned(UInt8(0))
        case .crlf: writer.unsigned(UInt8(1))
        case .cr: writer.unsigned(UInt8(2))
        }
        writer.unsigned(UInt32(fragments.count))
        writer.unsigned(UInt32(primaryIndex))
        if case .rectangle(let rectangle) = shape {
            writer.unsigned(rectangle.width.bitPattern)
            writer.unsigned(UInt8((rectangle.zeroWidth ? 1 : 0) | (rectangle.reversed ? 2 : 0)))
            writer.unsigned(UInt32(rectangle.anchorRow))
            writer.unsigned(UInt32(rectangle.headRow))
        }
        for fragment in fragments {
            try budget.check()
            writer.unsigned(UInt32(fragment.documentOrder))
            writer.unsigned(UInt8(fragment.reversed ? 1 : 0))
            writer.unsigned(UInt32(fragment.virtualStart))
            writer.unsigned(UInt32(fragment.virtualTail))
            writer.unsigned(UInt32(fragment.text.utf8.count))
            try writer.append(Data(fragment.text.utf8))
        }
        try budget.check()
        guard writer.data.count <= ClipboardLimits.encodedBytes else {
            throw NateError.message("剪贴板编码超过 96 MiB。")
        }
        return writer.data
    }

    /// 业务作用：私有载荷逐项验证格式、长度和真实 UTF-8，不把未知矩形或损坏内容降格成另一种粘贴。
    /// 参数说明:
    /// - data: 系统剪贴板或配置中取得的完整原始载荷，最多 96 MiB。
    /// - deadline: 整个读取或粘贴的共同截止。
    /// - permit: 当前仍可继续读取和发布。
    /// 返回：全部片段和形态完整有效时返回载荷，未知格式、保留标志、尾随字节或取消时失败。
    public static func decode(
        _ data: Data,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws -> ClipboardPayload {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        guard data.count <= ClipboardLimits.encodedBytes else {
            throw NateError.message("剪贴板原始载荷超过 96 MiB。")
        }
        var reader = ClipboardBinaryReader(data: data, budget: budget)
        guard try reader.bytes(8) == Data("NATECLIP".utf8), try reader.unsigned(UInt16.self) == 1 else {
            throw NateError.message("剪贴板格式未知，请使用明确的普通文本粘贴。")
        }
        let kind = try reader.unsigned(UInt8.self)
        let ending = try reader.unsigned(UInt8.self)
        let count = Int(try reader.unsigned(UInt32.self))
        let primary = Int(try reader.unsigned(UInt32.self))
        guard (1...ClipboardLimits.fragments).contains(count), primary < count else {
            throw NateError.message("剪贴板片段数量或主项无效。")
        }
        let lineEnding: LineEnding
        switch ending {
        case 0: lineEnding = .lf
        case 1: lineEnding = .crlf
        case 2: lineEnding = .cr
        default: throw NateError.message("剪贴板分隔换行规则未知。")
        }
        let shape: ClipboardShape
        switch kind {
        case 0: shape = .stream
        case 1: shape = .lines
        case 2:
            let width = Double(bitPattern: try reader.unsigned(UInt64.self))
            let flags = try reader.unsigned(UInt8.self)
            let anchor = Int(try reader.unsigned(UInt32.self))
            let head = Int(try reader.unsigned(UInt32.self))
            guard flags & 0xFC == 0 else {
                throw NateError.message("剪贴板矩形包含未知保留标志。")
            }
            shape = .rectangle(
                try ClipboardRectangle(
                    width: width,
                    reversed: flags & 2 != 0,
                    zeroWidth: flags & 1 != 0,
                    anchorRow: anchor,
                    headRow: head
                )
            )
        default:
            throw NateError.message("剪贴板选择形态未知。")
        }
        var fragments: [ClipboardFragment] = []
        var bytes = (count - 1) * lineEnding.text.utf8.count
        for _ in 0..<count {
            try budget.check()
            let order = Int(try reader.unsigned(UInt32.self))
            let flags = try reader.unsigned(UInt8.self)
            let start = Int(try reader.unsigned(UInt32.self))
            let tail = Int(try reader.unsigned(UInt32.self))
            let length = Int(try reader.unsigned(UInt32.self))
            guard flags & 0xFE == 0, tail <= 1_000_000,
                length <= ClipboardLimits.contentBytes - bytes,
                tail <= ClipboardLimits.contentBytes - bytes - length
            else {
                throw NateError.message("剪贴板片段的标志、原文或虚拟尾部超量。")
            }
            let raw = try reader.bytes(length)
            guard let text = UTF8Text.decode(raw) else {
                throw NateError.message("剪贴板片段不是完整有效的 UTF-8。")
            }
            fragments.append(
                try ClipboardFragment(
                    text: text,
                    documentOrder: order,
                    reversed: flags & 1 != 0,
                    virtualStart: start,
                    virtualTail: tail
                )
            )
            bytes += length + tail
        }
        guard reader.cursor == data.count else {
            throw NateError.message("剪贴板载荷包含未知尾随内容。")
        }
        let result = try ClipboardPayload(
            fragments: fragments,
            primaryIndex: primary,
            shape: shape,
            lineEnding: lineEnding
        )
        try budget.check()
        return result
    }
}
