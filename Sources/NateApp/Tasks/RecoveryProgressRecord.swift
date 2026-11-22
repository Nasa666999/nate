import Foundation
import NateStorage

enum RecoveryProgressKind: Sendable, Equatable {
    case workspace
    case sidebar
    case archive
}

enum RecoveryProgressResult: Sendable {
    case running
    case succeeded
    case failed(String)
    case deferred(String)
}

struct RecoveryProgressRecord: Sendable {
    let id: UUID
    let kind: RecoveryProgressKind
    let target: String
    let started: ContinuousClock.Instant
    let names: [UUID: String]
    let totalDocuments: Int
    let totalBytes: Int
    var event: RecoveryProgress = .waitingForStorage
    var currentDocument: UUID?
    var currentRevision: UInt64?
    var documentBytes = 0
    var completedBytes = 0
    var documentChunks = 0
    var completedChunks = 0
    var confirmedDocuments: Set<UUID> = []
    var entryConfirmed = false
    var file: String?
    var fileStage: FileSaveStage?
    var finished: ContinuousClock.Instant?
    var result: RecoveryProgressResult = .running
}
