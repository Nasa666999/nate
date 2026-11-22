import Foundation
import NateCore

struct MSSQLLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var commentDepth = 0
    var commentOrigin: Int?
    var previousByte: UInt8 = 32
    var preferredEnd: Int?
    var preferredStyle: UInt8 = 15
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct MSSQLCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct MSSQLLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [MSSQLCachedToken] = []
    var initial: MSSQLLexicalState?
}
