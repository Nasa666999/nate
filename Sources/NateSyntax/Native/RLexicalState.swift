import Foundation
import NateCore

struct RContinuation: Sendable, Equatable {
    var mode = 0
    var rawDelimiter: UInt8 = 0
    var dashes = 0
    var escapeOuter = 0
    var escapeDigits = 0
    var escapeHex = false
    var escapeBraced = false
    var atLineStart = true
}

struct RLexicalState: Sendable, Equatable {
    var continuation = RContinuation()
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
    var cachedRange: ByteRange?
    var cachedClasses: [UInt8] = []
    var cachedInitialContinuation: RContinuation?

    /// 业务作用：当前类别与原始字符串及转义状态共同属于同一连续正文检查点。
    /// 参数说明: 无。
    /// 返回：当前原生类别，赋值只更新本检查点的类别。
    var mode: Int {
        get {
            continuation.mode
        }
        set {
            continuation.mode = newValue
        }
    }
}
