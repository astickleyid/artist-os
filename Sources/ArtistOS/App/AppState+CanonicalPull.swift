import Foundation
import ArtistOSCore

@MainActor
extension AppState {
    /// Applies one remote sync batch through the shared canonical conflict
    /// resolver and the atomic GRDB persistence bridge. This is the only path
    /// macOS pull code should use once the legacy inline loop is retired.
    ///
    /// The live catalog is replaced only after persistence succeeds. Selection
    /// state is then repaired if a remote tombstone removed the selected Song
    /// or Asset, and the existing decision engine is allowed to derive any
    /// legacy compatibility flags from the resulting catalog.
    @discardableResult
    func applyCanonicalCloudChanges(
        _ changes: [SyncLogic.JSONDict]
    ) throws -> [CanonicalSync.AppliedChange] {
        let applied = try CanonicalSyncPersistence.apply(
            changes: changes,
            to: &catalog,
            store: store
        )

        guard !applied.isEmpty else { return [] }

        if let selectedSongID,
           !catalog.songs.contains(where: { $0.id == selectedSongID }) {
            self.selectedSongID = catalog.songs.first?.id
        }
        if let selectedAssetID,
           !catalog.assets.contains(where: { $0.id == selectedAssetID }) {
            self.selectedAssetID = nil
        }

        runDecisionEngine()
        return applied
    }
}
