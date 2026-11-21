struct LispLexicalState: Sendable, Equatable {
    var style = 0
    var radix = -1
    var nextOffset: Int?
}
