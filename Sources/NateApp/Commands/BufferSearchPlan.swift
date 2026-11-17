import NateCore
import NateSearch
import NateUI

struct BufferSearchCapture: Sendable {
    let snapshot: DocumentSnapshot
    let scope: ResolvedSearchScope
    let label: String
    let bookmarks: Set<Int>?
}

struct BufferSearchPlan: Sendable {
    let snapshot: DocumentSnapshot
    let hitCount: Int
    let edits: [TextEdit]
    let transaction: PreparedTransaction?
    let previews: [SearchPreviewRow]
    let originalBookmarks: Set<Int>?
    let bookmarkPlan: SearchBookmarkPlan?
}
