import Foundation
import NateCore

extension AutoItScanner {
    /// 业务作用：原生候选最多读取九十九字节，缓存饱和后的长名称不重复复制相同前缀。
    /// 参数说明: 无。
    /// 返回：原生 ASCII 小写及 CString NUL 收束后的完整候选；预算不足时抛错。
    mutating func candidate() throws -> Data {
        if candidateBase != emitted {
            candidateBase = emitted
            candidateRawCount = 0
            candidateTerminated = false
            candidateValue = Data()
        }
        let end = min(cursor, bytes.count, emitted + 99)
        while candidateRawCount < end - emitted {
            try budget.consume()
            let value = bytes[emitted + candidateRawCount]
            candidateRawCount += 1
            if !candidateTerminated {
                if value == 0 {
                    candidateTerminated = true
                }
                else {
                    candidateValue.append(AutoItCharacters.lower(value))
                }
            }
        }
        return candidateValue
    }

    /// 业务作用：EOF 的原生保存候选延迟读取，逐字符记录范围不为长名称反复复制同一份原文。
    /// 参数说明: 无。
    /// 返回：原生保存描述符还原为九十九字节以内的有限候选；范围或预算不足时整份失败。
    mutating func savedCandidate() throws -> Data {
        guard let saved else {
            return Data()
        }
        guard saved.start >= 0, saved.end >= saved.start, saved.end <= bytes.count else {
            throw NateError.invalidRange
        }
        var output = Data()
        for index in saved.start..<min(saved.end, saved.start + 99) {
            try budget.consume()
            let value = bytes[index]
            if value == 0 {
                break
            }
            output.append(AutoItCharacters.lower(value))
        }
        if output.count < 99 {
            output.append(saved.character)
        }
        return output
    }

    /// 业务作用：七组已启用词表保持原生优先级，未启用的 UDF 词表不能取得第八组查询资格。
    /// 参数说明:
    /// - candidate: 已确认的原生 ASCII 小写候选。
    /// - final: 是否采用真实 EOF 保存候选的展开规则。
    /// 返回：指令、函数、宏、预处理、特殊、展开或默认类别；规则或预算不足时抛错。
    mutating func classify(_ candidate: Data, final: Bool = false) throws -> UInt8 {
        if candidate == Data("#cs".utf8) || candidate == Data("#comments-start".utf8) {
            return 2
        }
        for (group, style): (Int, UInt8) in [(0, 5), (1, 4), (2, 6), (4, 11), (5, 12)] {
            if try rules.contains(candidate, group: group, budget: &budget) {
                return style
            }
        }
        if try rules.contains(candidate, group: 6, budget: &budget) {
            let allowed: Bool
            if final {
                allowed = try atLineEnd()
            }
            else {
                allowed = try !AutoItCharacters.operation(current())
            }
            if allowed {
                return 13
            }
        }
        if !final && candidate == Data([95]) {
            return 8
        }
        return 0
    }
}
