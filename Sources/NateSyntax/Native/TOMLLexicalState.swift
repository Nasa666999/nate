import Foundation
import NateCore

struct TOMLLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var keyState: UInt8 = 0
    var braceCount = 0
    var tableLevel = 0
    var lineType: UInt8 = 0
    var visibleChars = 0
    var previousNonWhite: UInt32 = 0
    var previousScalar: UInt32 = 0
    var atLineStart = true
    var escapeOuter: UInt8 = 0
    var escapeDigits = 0
    var prefix: [UInt8] = []
    var lastLineState: UInt32 = 0
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct TOMLCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct TOMLLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [TOMLCachedToken] = []
}
