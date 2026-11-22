import Foundation
import NateCore

struct ObjCContinuation: Sendable, Equatable {
    var mode = 0
    var previousNonwhite: UInt8 = 32
    var visible = 0
    var lastUUID = false
}

struct ObjCLexicalState: Sendable, Equatable {
    var continuation = ObjCContinuation()
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
    var cachedRange: ByteRange?
    var cachedClasses: [UInt8] = []
    var cachedInitialContinuation: ObjCContinuation?

    /// 业务作用：当前类别与续行上下文共用同一状态，片段结束不能丢失前置代码证据。
    /// 参数说明: 无。
    /// 返回：当前独立词法类别，赋值只推进本检查点的类别。
    var mode: Int {
        get {
            continuation.mode
        }
        set {
            continuation.mode = newValue
        }
    }
}
