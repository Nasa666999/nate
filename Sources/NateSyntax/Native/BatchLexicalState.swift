import Foundation
import NateCore

struct BatchLexicalState: Sendable, Equatable {
    var processing = true
    var unassigned = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct BatchCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct BatchLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [BatchCachedToken] = []
    var initial: BatchLexicalState?
}
