import Foundation
import NateCore

struct ScriptCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: String
    let style: UInt8
}

struct ScriptLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [ScriptCachedToken] = []
    var initial: CLexicalState?
}
