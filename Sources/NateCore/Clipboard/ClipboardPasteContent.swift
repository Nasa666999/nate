import Foundation

public struct ClipboardPasteContent: Sendable {
    public let payload: ClipboardPayload
    public let documentValues: [String]
    public let plainText: String

    /// 业务作用：在后台准备一次粘贴的全部真实内容，换行适配只影响将插入的片段。
    /// 参数说明:
    /// - payload: 已完整校验的剪贴板形态与原始内容。
    /// - adaptingTo: 明确启用适配时使用的文档换行规则，省略时保留原字节。
    /// - deadline: 解码和事务准备共用的截止。
    /// - permit: 本轮读取与准备仍有效。
    /// 返回：文档顺序片段与建立顺序普通文本；取消、超时或适配后超过 64 MiB 时完整失败。
    public init(
        payload: ClipboardPayload,
        adaptingTo: LineEnding? = nil,
        deadline: ContinuousClock.Instant? = nil,
        permit: @escaping @Sendable () -> Bool = {
            true
        }
    ) throws {
        let budget = ClipboardBudget(deadline: deadline, permit: permit)
        try budget.check()
        var values: [String] = []
        var total = 0
        let separator = adaptingTo ?? payload.lineEnding
        for fragment in payload.documentFragments {
            try budget.check()
            let text = try Self.adapt(fragment.text, to: adaptingTo, budget: budget)
            let size = text.utf8.count + fragment.virtualTail
            guard size <= ClipboardLimits.contentBytes - total else {
                throw NateError.message("适配换行后的剪贴板内容超过 64 MiB。")
            }
            total += size
            values.append(text + String(repeating: " ", count: fragment.virtualTail))
        }
        let separators = (values.count - 1) * separator.text.utf8.count
        guard separators <= ClipboardLimits.contentBytes - total else {
            throw NateError.message("剪贴板内容与分隔换行合计超过 64 MiB。")
        }
        var plain = ""
        plain.reserveCapacity(total + separators)
        for (index, fragment) in payload.fragments.enumerated() {
            try budget.check()
            if index > 0 {
                plain += separator.text
            }
            plain += values[fragment.documentOrder]
        }
        self.payload = payload
        documentValues = values
        plainText = plain
        try budget.check()
    }

    /// 业务作用：按原始 CR、LF、CRLF 字节转换插入内容，NUL 和 Unicode 组合形式保持不变。
    /// 参数说明:
    /// - text: 已受剪贴板容量限制的原文。
    /// - ending: 明确的目标换行，省略时原样共享文字。
    /// - budget: 所属动作共同截止与取消资格。
    /// 返回：完整适配文字；扩展容量、取消或超时则失败。
    private static func adapt(_ text: String, to ending: LineEnding?, budget: ClipboardBudget) throws
        -> String
    {
        guard let ending else {
            return text
        }
        var result: [UInt8] = []
        result.reserveCapacity(text.utf8.count)
        let replacement = Array(ending.text.utf8)
        var previousCR = false
        for (index, byte) in text.utf8.enumerated() {
            if index & 8191 == 0 {
                try budget.check()
            }
            if byte == 10 && previousCR {
                previousCR = false
                continue
            }
            previousCR = byte == 13
            let size = byte == 10 || byte == 13 ? replacement.count : 1
            guard size <= ClipboardLimits.contentBytes - result.count else {
                throw NateError.message("适配换行后的单个剪贴板片段超过 64 MiB。")
            }
            if byte == 10 || byte == 13 {
                result.append(contentsOf: replacement)
            }
            else {
                result.append(byte)
            }
        }
        try budget.check()
        return String(decoding: result, as: UTF8.self)
    }
}
