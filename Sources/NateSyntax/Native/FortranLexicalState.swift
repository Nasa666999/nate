import Foundation
import NateCore

struct FortranLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var previousStringMode: UInt8 = 0
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct FortranCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct FortranLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [FortranCachedToken] = []
}
