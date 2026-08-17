import Foundation
import ArtistOSCore

/// Bridges the pure cross-platform CanonicalSync application algorithm to the
/// macOS GRDB store. Remote changes are first applied to a candidate catalog;
/// the accepted batch is then persisted in one SQLite transaction. The caller's
/// in-memory catalog is only replaced after that transaction succeeds, so memory
/// and disk cannot diverge on a partial sync write.
enum CanonicalSyncPersistence {
    @discardableResult
    static func apply(
        changes: [SyncLogic.JSONDict],
        to catalog: inout ArtistCatalog,
        store: CatalogStore
    ) throws -> [CanonicalSync.AppliedChange] {
        var candidate = catalog
        let applied = CanonicalSync.apply(changes: changes, to: &candidate)
        guard !applied.isEmpty else { return [] }

        try store.persistCanonicalSync(applied, catalog: candidate)
        catalog = candidate
        return applied
    }
}
