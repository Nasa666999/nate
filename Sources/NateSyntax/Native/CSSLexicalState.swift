import Foundation
import NateCore

struct CSSLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var beforeOperator: Int8 = -1
    var beforeComment: Int8 = -1
    var beforeString: Int8 = -1
    var op: UInt32 = 32
    var opPrevious: UInt32 = 32
    var insideParentheses = false
    var previousScalar: UInt32 = 0
    var backslashes = 0
    var segmentOrigin = 0
    var segmentLength = 0
    var prefix: [UInt8] = []
    var physicalBoundary = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct CSSCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct CSSLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [CSSCachedToken] = []
    var initial: CSSLexicalState?
}

struct CSSPhysicalBoundary {
    let offset: Int
    let state: CSSLexicalState
}
