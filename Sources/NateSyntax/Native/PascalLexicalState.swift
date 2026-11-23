import Foundation
import NateCore

struct PascalLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var inAssembler = false
    var inProperty = false
    var inExports = false
    var multilineQuotes = 0
    var inStringIndent = true
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct PascalCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct PascalLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [PascalCachedToken] = []
}
