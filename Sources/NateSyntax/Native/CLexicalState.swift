import Foundation
import NateCore

struct CLexicalState: Sendable, Equatable {
    var language: String?
    var documentID: UUID?
    var revision: UInt64?
    var nextOffset: Int?
    var previousNonWhite: UInt8 = 32
    var lastAddWasDoubled = false
    var lastRawByte: UInt8?
    var operatorPending = false
    var regex = false
    var regexClass = false
    var regexEscape = false
    var regexFlags = false
    var lineStartPending = false
    var continuationLine = false
    var blockComment = false
    var lineComment = false
    var documentation = false
    var blockStar = false
    var quote: UInt8?
    var escape = false
    var escapeDigits = 0
    var escapeRadix: UInt8?
    var rawEnding: [UInt8] = []
    var rawMatched = 0
    var rawVisibleBeforeMatch: UInt8?
    var verbatim = false
    var header = false
    var preprocessor = false
    var directiveWord = false
    var expectsHeader = false
    var logicalStart = true
    var skipSplicedLineFeed = false
    var continuedWord = false
    var splicedWord = false
    var continuedNumber = false
    var numberUserLiteral = false
    var directivePrefix = ""
    var xmlContinuation: CXMLContinuation?
    var xmlTerminator = false
    var scriptResource: Data?
    var scriptSourceIdentity: UUID?
    var scriptPreprocessorComment = false
    var scriptPreprocessorQuote = false
    var templateDepths: [Int] = []
    var templateDelimiter: [UInt8] = []
}

struct CXMLContinuation: Sendable, Equatable {
    let documentID: UUID
    let revision: UInt64
    var nextOffset: Int
    let endOffset: Int
    let style: String
    let closesBlock: Bool
}

struct CLexingBudget {
    let deadline: ContinuousClock.Instant
    private var remaining = 4_194_304
    private var steps = 0

    /// 业务作用：整行词元、字面匹配与状态传播共用扫描器截止，不在长词元中重新授予时间。
    /// 参数说明:
    /// - deadline: 当前固定快照扫描器的共同截止。
    /// 返回：四百万步以内的独立行预算。
    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    /// 业务作用：所有字节和有限标记比较都计入共同预算，并定期响应真实取消。
    /// 参数说明: 无。
    /// 返回：有剩余工作量时继续，超限、取消或超时拒绝整行中间结果。
    mutating func consume() throws {
        guard remaining > 0 else {
            throw NateError.message("C/C++ 词法扫描超过四百万步，当前范围保持中性呈现。")
        }
        remaining -= 1
        steps += 1
        if steps & 255 == 0 {
            try check()
        }
    }

    /// 业务作用：入口与原子发布前复验同一截止，最后不足检查间隔的内容也不能绕过失权门禁。
    /// 参数说明: 无。
    /// 返回：当前任务仍有完整资格时继续，否则抛错并保留原检查点。
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw NateError.message("C/C++ 词法扫描超过共同截止，当前范围保持中性呈现。")
        }
    }
}
