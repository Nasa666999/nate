import Foundation
import NateCore

struct SQLLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var previousScalar: UInt32 = 0
    var qComplement: UInt32 = 0
    var closingQuotePending = false
    var lineCommentEnded = false
    var physicalBoundary = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct SQLCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct SQLLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [SQLCachedToken] = []
    var initial: SQLLexicalState?
}
