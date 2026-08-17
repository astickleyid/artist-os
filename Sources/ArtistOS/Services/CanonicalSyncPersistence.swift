import Foundation
import ArtistOSCore

/// Bridges the pure cross-platform CanonicalSync application algorithm to the
/// macOS GRDB store. The in-memory catalog is mutated first; only changes that
/// CanonicalSync actually accepts under its LWW/identity rules are persisted.
enum CanonicalSyncPersistence {
    @discardableResult
    static func apply(
        changes: [SyncLogic.JSONDict],
        to catalog: inout ArtistCatalog,
        store: CatalogStore
    ) throws -> [CanonicalSync.AppliedChange] {
        let applied = CanonicalSync.apply(changes: changes, to: &catalog)

        for change in applied {
            switch change.kind {
            case .song:
                if change.deleted {
                    try store.delete(songID: change.id)
                } else if let song = catalog.songs.first(where: { $0.id == change.id }) {
                    try store.upsert(song: song)
                }

            case .asset:
                if change.deleted {
                    try store.delete(assetID: change.id)
                } else if let asset = catalog.assets.first(where: { $0.id == change.id }) {
                    try store.insert(asset: asset)
                }

            case .event:
                if change.deleted {
                    try store.delete(eventID: change.id)
                } else if let event = catalog.events.first(where: { $0.id == change.id }) {
                    try store.append(event: event)
                }

            case .decision:
                if change.deleted {
                    try store.delete(decisionID: change.id)
                } else if let decision = catalog.decisions.first(where: { $0.id == change.id }) {
                    try store.append(decision: decision)
                }

            case .masterComposition:
                if change.deleted {
                    try store.delete(masterCompositionID: change.id)
                } else if let composition = catalog.masterCompositions.first(where: { $0.id == change.id }) {
                    try store.upsert(masterComposition: composition)
                }
            }
        }

        return applied
    }
}