import Foundation

public enum EditorCommand: String, CaseIterable, Codable, Sendable {
    case deleteBackward, deleteForward
    case insertTab, backTab
    case insertNewline
    case insertMarkupTagEnd
    case insertOpeningBrace, insertClosingBrace, insertOpeningBracket, insertClosingBracket
    case insertClosingParenthesis
    case moveLeft, moveRight, moveUp, moveDown
    case extendLeft, extendRight, extendUp, extendDown
    case lineStart, lineEnd, extendLineStart, extendLineEnd
    case documentStart, documentEnd, extendDocumentStart, extendDocumentEnd
    case wordLeft, wordRight, extendWordLeft, extendWordRight
    case selectAll, collapseSelection

    /// 业务作用：独立结构字符的宏保存输入意图，播放时采用目标正文当前语言的缩进规则。
    /// 参数说明: 无。
    /// 返回：受支持的字面界定符，其它编辑动作没有结构字符载荷。
    public var structuralCharacter: String? {
        switch self {
        case .insertOpeningBrace: return "{"
        case .insertClosingBrace: return "}"
        case .insertOpeningBracket: return "["
        case .insertClosingBracket: return "]"
        case .insertClosingParenthesis: return ")"
        default: return nil
        }
    }
}
