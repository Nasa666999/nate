import Foundation
import NateCore

struct LuaPendingSpan: Sendable, Equatable {
    var bytes: Int
    let style: Int
}

struct LuaContinuation: Sendable, Equatable {
    var mode = 0
    var separator = 0
    var stringWhitespace = false
    var documentComment = false
    var atLineStart = true
    var pending: [LuaPendingSpan] = []
}

struct LuaLexicalState: Sendable, Equatable {
    var continuation = LuaContinuation()
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
    var cachedRange: ByteRange?
    var cachedClasses: [UInt8] = []
    var cachedInitialContinuation: LuaContinuation?

    /// 业务作用：独立类别与跨行分隔符共同传播，外部结构判断只读取当前明确的词法身份。
    /// 参数说明: 无。
    /// 返回：当前原生类别；赋值仅改变类别，不丢失长字面与空白转义的延续信息。
    var mode: Int {
        get {
            continuation.mode
        }
        set {
            continuation.mode = newValue
        }
    }
}
