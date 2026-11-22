import Foundation

struct UDLWordTail: Sendable, Equatable {
    let end: Int
    let style: String
}

struct UDLWordContinuation: Sendable, Equatable {
    var next: Int
    let end: Int
    let style: String
    let action: SyntaxFoldAction?
    let insideComment: Bool
    let documentID: UUID
    let revision: UInt64
    let sourceIdentity: UUID
    let tail: UDLWordTail?
    var isForward = false
}
