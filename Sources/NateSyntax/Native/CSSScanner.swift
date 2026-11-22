import Foundation
import NateCore

enum CSSScannerSignal: Error {
    case ready
}

struct CSSScannedChunk {
    let range: ByteRange
    let state: CSSLexicalState
    let tokens: [CSSCachedToken]
}

struct CSSScanner {
    var bytes: [UInt8]
    let base: Int
    let wantedUpper: Int
    let snapshot: DocumentSnapshot?
    var trueEOF: Bool
    let limitUpper: Int
    let rules: CSSRules
    var prefixOnly = false
    var budget: ANSILexingBudget
    var state: CSSLexicalState
    var cursor = 0
    var emitted = 0
    var tokens: [CSSCachedToken] = []
    var lastBoundary: CSSPhysicalBoundary?
    var safeBoundary: CSSPhysicalBoundary?

    /// 业务作用：普通 CSS 在固定正文中确认当前未决词法段，稳定边界之前的类别才能交付显示。
    /// 参数说明: 无。
    /// 返回：有界完整缓存及其真实物理边界状态；超量、来源不足或取消时不返回部分结果。
    mutating func scan() throws -> CSSScannedChunk {
        try budget.check()
        do {
            while cursor < bytes.count || cursor == bytes.count && !prefixOnly {
                try budget.consume()
                try requireCurrent()
                if state.mode == 9, current == 42, try next() == 47 {
                    guard state.beforeComment >= 0 else {
                        throw NateError.message("CSS 注释缺少完整前置类别。")
                    }
                    let saved = UInt8(state.beforeComment)
                    try advance()
                    try advance()
                    try setMode(saved)
                }
                if state.mode == 9 {
                    try advance()
                    continue
                }
                if state.mode == 13 || state.mode == 14 {
                    let quote: UInt32 = state.mode == 13 ? 34 : 39
                    if current != quote || state.backslashes & 1 == 1 {
                        try advance()
                        continue
                    }
                    guard state.beforeString >= 0 else {
                        throw NateError.message("CSS 字符串缺少完整前置类别。")
                    }
                    let saved = UInt8(state.beforeString)
                    try advance()
                    try setMode(saved)
                }
                if prefixOnly, cursor >= bytes.count {
                    break
                }
                // 缓冲区末端不能伪装真实 EOF，缺少后继时不为未决名称提前定类。
                try requireCurrent()
                if state.mode == 5 {
                    try operatorContext()
                }
                if current == 42, state.mode == 0 {
                    try setMode(1)
                    try advance()
                    continue
                }
                if current == 40 {
                    state.insideParentheses = true
                }
                else if current == 41 {
                    state.insideParentheses = false
                }
                if Self.word(current) {
                    if state.mode == 0 {
                        try setMode(1)
                    }
                    try advance()
                    continue
                }
                if Self.word(state.previousScalar), Self.pending(state.mode) {
                    try classify()
                }
                if ![46, 58, 35].contains(current),
                    state.mode == 2 || state.mode == 10
                        || ![40, 41].contains(current) && [3, 18, 20, 21, 4].contains(state.mode)
                {
                    try setMode(1)
                }
                if current == 47, try next() == 42 {
                    state.beforeComment = Int8(state.mode)
                    try setMode(9)
                    try advance()
                }
                else if (state.mode == 8 || state.mode == 16), current == 34 || current == 39 {
                    state.beforeString = Int8(state.mode)
                    try setMode(current == 34 ? 13 : 14)
                }
                else if Self.op(current),
                    state.mode != 16 || current == 93,
                    state.mode != 8 || [59, 125, 33].contains(current),
                    ![12, 22].contains(state.mode) || current == 59 || current == 123
                {
                    if state.mode != 5 {
                        state.beforeOperator = Int8(state.mode)
                    }
                    try setMode(5)
                    state.op = current
                    state.opPrevious = state.previousScalar
                }
                try advance()
            }
        }
        catch CSSScannerSignal.ready {
            return try finish()
        }
        return try finish()
    }
}
