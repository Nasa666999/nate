import AppKit

struct TabDragGesture: Equatable {
    let owner: UUID
    let gesture: UUID
    let documentID: UUID
    let order: UUID
}
