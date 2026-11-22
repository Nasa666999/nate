import Foundation
import NateCore

extension TOMLScanner {
    /// 业务作用：真实物理结束符决定 TOML 行尾，最后未结束行只在真实 EOF 结束。
    /// 参数说明: 无。
    /// 返回：当前标量已到本原生物理行的行尾时为真。
    var atLineEnd: Bool {
        if physicalStart < physicalEnd, [10, 13].contains(bytes[physicalEnd - 1]) {
            return cursor >= physicalEnd - 1
        }
        return trueEOF && cursor >= physicalEnd
    }

    /// 业务作用：物理边界只采用 CR、LF、CRLF，Unicode 显示换行不重置原生行状态。
    /// 参数说明:
    /// - start: 新物理行在缓冲区中的起点。
    /// 返回：该行完整原字节末端，逐字节读取计入共同预算。
    mutating func nextPhysicalEnd(from start: Int) throws -> Int {
        var end = min(start, bytes.count)
        while end < bytes.count {
            try budget.consume()
            let byte = bytes[end]
            end += 1
            if byte == 10 {
                break
            }
            if byte == 13 {
                if end < bytes.count, bytes[end] == 10 {
                    end += 1
                }
                break
            }
        }
        return end
    }

    /// 业务作用：原生 Forward 只推进标量和物理边界，可见计数及行元数据由循环的实际当前位置发布。
    /// 参数说明: 无。
    /// 返回：完整标量或 EOF 哨兵消费，后继行开端和有限词候选同步推进。
    mutating func advance() throws {
        try budget.consume()
        let end = atLineEnd, count = width(at: cursor), value = current
        if cursor < bytes.count {
            guard count <= bytes.count - cursor else {
                throw NateError.invalidRange
            }
            if state.prefix.count < 7 {
                state.prefix.append(contentsOf: bytes[cursor..<cursor + min(count, 7 - state.prefix.count)])
            }
        }
        state.previousScalar = value
        state.atLineStart = end
        cursor += count
        if end {
            physicalStart = min(cursor, bytes.count)
            physicalEnd = try nextPhysicalEnd(from: physicalStart)
        }
    }

    /// 业务作用：TOML SetState 封闭旧段，后继 ChangeState 只能重新定义当前尚未封闭的片段。
    /// 参数说明:
    /// - mode: 新原生类别。
    /// 返回：旧段完整类别进入暂存，新段候选复位；越界或预算不足时拒绝。
    mutating func setMode(_ mode: UInt8) throws {
        try emit(until: min(cursor, bytes.count), style: state.mode)
        state.mode = mode
        state.prefix = []
    }

    /// 业务作用：只有已确认类别的顺序范围进入当前物理暂存，不向调用者发布半个名称或字面。
    /// 参数说明:
    /// - end: 不包含的本行字节末端。
    /// - style: 本段完整原生类别。
    /// 返回：完整暂存范围前进，越界或超预算时拒绝整份结果。
    mutating func emit(until end: Int, style: UInt8) throws {
        guard end >= emitted, end <= bytes.count, style <= 15 else {
            throw NateError.invalidRange
        }
        for index in emitted..<end {
            try budget.consume()
            styles[index] = style
        }
        emitted = end
    }
}
