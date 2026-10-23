import Foundation

/// A listing owns only its own child processes. Mutable fields are protected by
/// RcloneEngine's state lock, including the check immediately before spawning.
final class EngineListing {
    let id: String
    let done = DispatchGroup()
    var prepared = false
    var claimed = false
    var finished = false
    var finishedAt: Date?
    var deadline: Date?
    var stop: EngineListingStop?
    var child: Process?

    init(id: String) {
        self.id = id
    }
}

enum EngineListingStop: Error, LocalizedError, Equatable {
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cancelled: return "目錄讀取已取消。"
        case .timedOut: return "rclone 回應逾時，請檢查連線後重試。"
        }
    }
}
