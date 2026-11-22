import Foundation
import NateCore

struct CMakeLexicalState: Sendable, Equatable {
    var mode: UInt8 = 0
    var variableInString = false
    var classicInString = false
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
}

struct CMakeCachedToken: Sendable, Equatable {
    let range: ByteRange
    let kind: SyntaxKind
    let style: UInt8
}

struct CMakeLexicalCache: Sendable, Equatable {
    var nextOffset: Int?
    var range: ByteRange?
    var tokens: [CMakeCachedToken] = []
}
