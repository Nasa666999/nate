import Foundation
import NateCore

struct TOMLScanner {
    let bytes: [UInt8]
    let base: Int
    let snapshot: DocumentSnapshot?
    let trueEOF: Bool
    let rules: TOMLRules
    var budget: ANSILexingBudget
    var state: TOMLLexicalState
    var cursor = 0
    var emitted = 0
    var physicalStart = 0
    var physicalEnd = 0
    var styles: [UInt8]

    /// 业务作用：TOML 先完整确认物理范围内的键、值及真实行元数据，再交付显示类别。
    /// 参数说明: 无。
    /// 返回：完整逐字节类别和后继状态；来源、容量或截止不足时拒绝整批结果。
    mutating func scan() throws -> ([UInt8], TOMLLexicalState) {
        physicalEnd = try nextPhysicalEnd(from: 0)
        // 真实结束符之后的空行由自己的连续请求处理，不能用空行元数据覆盖当前物理行。
        let endsInEOL =
            bytes.last.map {
                $0 == 10 || $0 == 13
            } ?? false
        let includesEOF = trueEOF && !endsInEOL
        while cursor < bytes.count || includesEOF && cursor == bytes.count {
            try budget.consume()
            switch state.mode {
            case 8:
                try setMode(0)
            case 4:
                if try !Self.decimal(state.previousScalar, current, next()) {
                    if try Self.isoDate(current, next()) {
                        state.mode = 14
                    }
                    else if try isKey(keyword: false) {
                        state.keyState = 0
                        continue
                    }
                }
            case 14:
                if try !(Self.identifier(current) || Self.isoDate(current, next())) {
                    if try isKey(keyword: false) {
                        state.keyState = 0
                        continue
                    }
                }
            case 2:
                if !Self.identifier(current), try isKey(keyword: true) {
                    state.keyState = 0
                    continue
                }
            case 5, 6:
                if try keyOrTable() {
                    continue
                }
            case 9, 10, 11, 12:
                if try string() {
                    continue
                }
            case 15:
                if state.atLineStart {
                    try setMode(0)
                }
            case 13:
                state.escapeDigits -= 1
                if state.escapeDigits <= 0 || !Self.hex(current) {
                    try setMode(state.escapeOuter)
                    continue
                }
            case 7:
                if state.atLineStart {
                    try setMode(0)
                }
                else if current == 35 {
                    try setMode(1)
                }
            case 1:
                if state.atLineStart {
                    try setMode(0)
                }
            default:
                break
            }
            if state.mode == 0 {
                try beginToken()
            }
            if !Self.space(current) {
                guard state.visibleChars < 2_097_152 else {
                    throw NateError.message("TOML 可见原字节范围超过完整容量。")
                }
                state.previousNonWhite = current
                state.visibleChars += 1
            }
            if atLineEnd {
                publishLine()
            }
            try advance()
        }
        try emit(until: bytes.count, style: state.mode)
        try budget.check()
        return (styles, state)
    }

    /// 业务作用：TOML 每个真实物理行独立发布表头及注释属性，字面和容器状态继续传播。
    /// 参数说明: 无。
    /// 返回：原生行编码保留，行内键名、计数与表头局部状态复位。
    mutating func publishLine() {
        let packed =
            (UInt64(state.tableLevel) << 2) | (UInt64(state.braceCount) << 10)
            | UInt64(state.lineType)
        state.lastLineState = UInt32(truncatingIfNeeded: packed)
        state.lineType = 0
        state.visibleChars = 0
        state.previousNonWhite = 0
        state.tableLevel = 0
        state.keyState = 0
    }
}
