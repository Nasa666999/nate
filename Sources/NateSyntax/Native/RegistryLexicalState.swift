import Foundation

struct RegistryLexicalState: Sendable, Equatable {
    var style = 0
    var beforeGUID = 0
    var beforeEscape = 0
    var afterEqualSign = false
    var highlight = false
    var tail: [UInt8] = []
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
}
