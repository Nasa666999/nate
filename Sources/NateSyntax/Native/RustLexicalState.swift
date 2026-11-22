import Foundation
import NateCore

struct RustLexicalState: Sendable, Equatable {
    var style = 0
    var depth = 0
    var hashes = 0
    var lineComment = false
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
    var cachedRange: ByteRange?
    var cachedClasses: [UInt8] = []
    var cachedInitial: RustLiteralState?
}

struct RustLiteralState: Sendable, Equatable {
    let style: Int
    let depth: Int
    let hashes: Int
    let lineComment: Bool
}
