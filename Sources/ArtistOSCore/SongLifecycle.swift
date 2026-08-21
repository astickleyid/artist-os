import Foundation

/// Pure Song lifecycle transitions. Archiving changes only the Song's workflow
/// visibility/state; creative evidence and history live outside this value and
/// must remain untouched by callers.
public enum SongLifecycle {
    public static func archive(_ song: Song, at timestamp: Date = Date()) -> Song {
        guard song.status != .archived else { return song }
        var updated = song
        updated.status = .archived
        updated.updatedAt = timestamp
        return updated
    }

    public static func restore(
        _ song: Song,
        to status: SongStatus = .review,
        at timestamp: Date = Date()
    ) -> Song {
        guard song.status == .archived, status != .archived else { return song }
        var updated = song
        updated.status = status
        updated.updatedAt = timestamp
        return updated
    }
}
