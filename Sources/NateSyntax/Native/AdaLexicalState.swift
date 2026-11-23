import Foundation
import NateCore

struct AdaLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var apostropheStartsAttribute = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct AdaCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct AdaLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [AdaCachedToken] = []
}
