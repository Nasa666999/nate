import Foundation
import NateCore

struct NncronLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var insideString = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct NncronCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct NncronLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [NncronCachedToken] = []
}
