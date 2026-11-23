import Foundation
import NateCore

struct ASN1LexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var oid = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct ASN1CachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct ASN1LexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [ASN1CachedToken] = []
}
