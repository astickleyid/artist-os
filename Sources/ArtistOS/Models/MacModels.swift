import Foundation

/// macOS-only model: watched folders (auto-import). Folder watching is not an
/// iOS paradigm (capture happens via mic/Files/Share Sheet there), so this
/// stays out of the shared core deliberately.
struct WatchedFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var path: String
    var bookmark: Data?
    var addedAt: Date

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}
