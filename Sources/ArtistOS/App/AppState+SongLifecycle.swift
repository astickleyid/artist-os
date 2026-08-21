import Foundation
import ArtistOSCore
import os

private let songLifecycleLogger = Logger(subsystem: "com.stickley.artistos", category: "SongLifecycle")

@MainActor
extension AppState {
    /// Removes a Song from the active workflow without destroying its identity,
    /// Assets, canonical Master Composition, Events, or Decisions.
    func archiveSong(id: UUID) {
        guard let index = catalog.songs.firstIndex(where: { $0.id == id }) else { return }
        let original = catalog.songs[index]
        let timestamp = Date()
        let updated = SongLifecycle.archive(original, at: timestamp)
        guard updated != original else { return }

        let event = CreativeEvent(
            id: UUID(),
            songID: id,
            timestamp: timestamp,
            target: .song,
            operation: .archived,
            beforeAssetID: nil,
            afterAssetID: nil,
            summary: "\(original.title) archived from the active catalog.",
            confidence: 1
        )
        let syncChanges = lifecycleSyncChanges(song: updated, event: event)

        do {
            try store.commitSongLifecycle(song: updated, event: event, syncChanges: syncChanges)
        } catch {
            songLifecycleLogger.error("Failed to archive Song: \(error.localizedDescription)")
            return
        }

        catalog.songs[index] = updated
        catalog.events.append(event)
        if selectedSongID == id {
            selectedSongID = catalog.songs.first(where: { $0.status != .archived })?.id
            selectedAssetID = nil
        }
        if !syncChanges.isEmpty { resumeCanonicalSyncOutbox() }
    }

    /// Returns an archived Song to the active workflow while preserving the same
    /// permanent Song identity and all existing creative history.
    func restoreSong(id: UUID, to status: SongStatus = .review) {
        guard let index = catalog.songs.firstIndex(where: { $0.id == id }) else { return }
        let original = catalog.songs[index]
        let timestamp = Date()
        let updated = SongLifecycle.restore(original, to: status, at: timestamp)
        guard updated != original else { return }

        let event = CreativeEvent(
            id: UUID(),
            songID: id,
            timestamp: timestamp,
            target: .song,
            operation: .structureUpdated,
            beforeAssetID: nil,
            afterAssetID: nil,
            summary: "\(original.title) restored to \(status.rawValue).",
            confidence: 1
        )
        let syncChanges = lifecycleSyncChanges(song: updated, event: event)

        do {
            try store.commitSongLifecycle(song: updated, event: event, syncChanges: syncChanges)
        } catch {
            songLifecycleLogger.error("Failed to restore Song: \(error.localizedDescription)")
            return
        }

        catalog.songs[index] = updated
        catalog.events.append(event)
        if !syncChanges.isEmpty { resumeCanonicalSyncOutbox() }
    }

    private func lifecycleSyncChanges(song: Song, event: CreativeEvent) -> [SyncLogic.JSONDict] {
        guard syncStatus == .on else { return [] }
        return [SyncLogic.change(forSong: song), SyncLogic.change(forEvent: event)]
    }
}
