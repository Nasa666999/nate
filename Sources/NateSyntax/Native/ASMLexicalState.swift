import Foundation
import NateCore

struct ASMLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var wordStyle: UInt8 = 5
    var directiveComment = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct ASMCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct ASMLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [ASMCachedToken] = []
}
