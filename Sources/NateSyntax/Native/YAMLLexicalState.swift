import Foundation
import NateCore

struct YAMLLexicalState: Sendable, Equatable {
    var textIndent: Int?
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
    var cachedRange: ByteRange?
    var cachedClasses: [UInt8] = []
    var cachedQuoted: [Bool] = []
}
