import Foundation
import NateCore

struct PowerShellLexicalState: Sendable, Equatable {
    var mode = 0
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var sourceIdentity: UUID?
    var resource: Data?
    var cachedRange: ByteRange?
    var cachedClasses: [UInt8] = []
    var cachedInitialMode: Int?
}
