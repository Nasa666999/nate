import Foundation
import NateCore

struct AutoItLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var string: UInt8 = 0
    var number: UInt8 = 0
    var comment: UInt8 = 0
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct AutoItCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct AutoItLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [AutoItCachedToken] = []
}
