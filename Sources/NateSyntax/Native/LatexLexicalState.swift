import Foundation

struct LatexLexicalState: Sendable, Equatable {
    var style = 0
    var mode = 0
    var verbatimDelimiter: UInt8 = 0
    var carriedStyle: Int?
    var nextOffset: Int?
    var documentID: UUID?
    var revision: UInt64?
    var tail: [UInt8] = []
}
