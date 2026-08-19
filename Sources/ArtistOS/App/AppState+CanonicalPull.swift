import Foundation
import ArtistOSCore

@MainActor
extension AppState {
    /// Applies one remote sync batch through the shared canonical conflict
    /// resolver and the atomic GRDB persistence bridge. This is the only path
    /// macOS pull code should use once the legacy inline loop is retired.
    @discardableResult
    func applyCanonicalCloudChanges(
        _ changes: [SyncLogic.JSONDict]
    ) throws -> [CanonicalSync.AppliedChange] {
        let previousSelectedSongID = selectedSongID
        let applied = try CanonicalSyncPersistence.apply(
            changes: changes,
            to: &catalog,
            store: store
        )

        // A resumed linked account always pulls at launch. Use that boundary to
        // restart any canonical delivery that survived a previous process exit,
        // even when the pull itself contains no new remote changes.
        resumeCanonicalSyncOutbox()

        guard !applied.isEmpty else { return [] }

        let selectedSongWasRemoved = previousSelectedSongID.map { previous in
            !catalog.songs.contains(where: { $0.id == previous })
        } ?? false

        if selectedSongWasRemoved {
            selectedSongID = catalog.songs.first?.id
            selectedAssetID = nil
        } else if let selectedAssetID,
                  !catalog.assets.contains(where: { $0.id == selectedAssetID }) {
            self.selectedAssetID = nil
        }

        runDecisionEngine()
        return applied
    }
}
