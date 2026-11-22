import Foundation
import NateCore

extension BatchScanner {
    /// 业务作用：原生固定命令比较保留完整词范围，NUL 不把 std::string_view 候选提前截断。
    /// 参数说明:
    /// - text: 待比较的固定 ASCII 命令。
    /// - count: 明确比较前缀时的长度；为空时比较完整词。
    /// 返回：完整候选与命令原字节相同时为真。
    mutating func equals(_ text: String, count: Int? = nil) throws -> Bool {
        let length = count ?? wordEnd - wordStart
        guard length == text.utf8.count else {
            return false
        }
        for (index, value) in text.utf8.enumerated() {
            try budget.consume()
            if word(index) != value {
                return false
            }
        }
        return true
    }

    /// 业务作用：双冒号命令注释只根据当前真实词的前缀识别。
    /// 参数说明:
    /// - text: 明确要求的 ASCII 前缀。
    /// 返回：当前完整词包含该前缀时为真。
    mutating func starts(_ text: String) throws -> Bool {
        guard text.utf8.count <= wordEnd - wordStart else {
            return false
        }
        return try equals(text, count: text.utf8.count)
    }

    /// 业务作用：Batch 候选逐字节计入共同预算后匹配所在词表，有限行中也不允许重复扫描绕过上限。
    /// 参数说明:
    /// - group: 内部命令或外部命令的明确词表位置。
    /// - count: 特殊命令前缀长度；为空时比较完整词。
    /// 返回：精确项或 caret 前缀匹配时为真，来源或预算不足时拒绝。
    mutating func listed(group: Int, count: Int? = nil) throws -> Bool {
        let length = count ?? wordEnd - wordStart
        guard length >= 0, length <= wordEnd - wordStart else {
            throw NateError.invalidRange
        }
        var value = Data()
        value.reserveCapacity(length)
        for index in 0..<length {
            try budget.consume()
            value.append(word(index))
        }
        return try rules.contains(value, group: group, budget: &budget)
    }

    /// 业务作用：外部命令词表为空时开放实际命令位置的名称，非空时只接受明确声明。
    /// 参数说明: 无。
    /// 返回：当前外部命令具有完整规则资格时为真。
    mutating func externalAllowed() throws -> Bool {
        try rules.groups[1].isEmpty || listed(group: 1)
    }

    /// 业务作用：原生 ColourTo 只覆盖尚未发布的顺序范围，注释或标签后的默认步骤不得撤销既有类别。
    /// 参数说明:
    /// - end: 当前物理行中包含在内的最后一个字节。
    /// - style: 本段完整原生类别。
    /// 返回：暂存类别沿顺序前进，越界或超预算时拒绝整行。
    mutating func colour(until end: Int, style: UInt8) throws {
        guard end < bytes.count, end >= -1, styles.count == bytes.count else {
            throw NateError.invalidRange
        }
        if end < painted {
            return
        }
        for index in painted...end {
            try budget.consume()
            styles[index] = style
        }
        painted = end + 1
    }
}
