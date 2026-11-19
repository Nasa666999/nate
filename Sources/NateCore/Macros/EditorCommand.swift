import Foundation

public enum EditorCommand: String, CaseIterable, Codable, Sendable {
    case deleteBackward, deleteForward
    case moveLeft, moveRight, moveUp, moveDown
    case extendLeft, extendRight, extendUp, extendDown
    case lineStart, lineEnd, extendLineStart, extendLineEnd
    case documentStart, documentEnd, extendDocumentStart, extendDocumentEnd
    case wordLeft, wordRight, extendWordLeft, extendWordRight
    case selectAll, collapseSelection
}
