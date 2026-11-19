import Foundation

struct RecoveryUnsupportedFormat: Error, LocalizedError {
    var errorDescription: String? {
        "恢复记录格式不受支持，现有工作区全部保留，未改用更早记录。"
    }
}
