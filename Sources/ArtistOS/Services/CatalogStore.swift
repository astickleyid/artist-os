import Foundation
import ArtistOSCore
import GRDB
import os

struct CanonicalSyncOutboxItem {
    let key: String
    let payload: Data
    let change: SyncLogic.JSONDict
}

enum CanonicalSyncOutboxError: LocalizedError {
    case missingKind
    case missingEntityID
    case invalidUpdatedAt
    case invalidJSONObject
    case invalidStoredPayload

    var errorDescription: String? {
        switch self {
        case .missingKind: return "Canonical sync change is missing a string kind."
        case .missingEntityID: return "Canonical sync change is missing a string id."
        case .invalidUpdatedAt: return "Canonical sync change is missing a valid numeric updatedAt."
        case .invalidJSONObject: return "Canonical sync change cannot be serialized as JSON."
        case .invalidStoredPayload: return "Canonical sync outbox contains an invalid stored payload."
        }
    }
}

/// Write-through persistence layer. The in-memory `ArtistCatalog` remains the
/// UI's source of truth; every mutation is mirrored to SQLite through this store.
final class CatalogStore {
    private let database: AppDatabase
    private let logger = Logger(subsystem: "com.stickley.artistos", category: "CatalogStore")

    init(database: AppDatabase) {
        self.database = database
    }

    static func makeDefault() -> CatalogStore {
        do {
            return CatalogStore(database: try AppDatabase.shared())
        } catch {
            Logger(subsystem: "com.stickley.artistos", category: "CatalogStore")
                .error("Falling back to in-memory database: \(error.localizedDescription)")
            return CatalogStore(database: try! AppDatabase.inMemory())
        }
    }

    var isEmpty: Bool {
        (try? database.dbQueue.read { db -> Bool in
            let songCount = try SongRecord.fetchCount(db)
            let assetCount = try AssetRecord.fetchCount(db)
            return songCount == 0 && assetCount == 0
        }) ?? true
    }

    func loadCatalog(artistName: String) -> ArtistCatalog {
        do {
            return try database.dbQueue.read { db in
                let songRecords = try SongRecord.fetchAll(db)
                let sectionRecords = try SectionRecord.order(Column("position")).fetchAll(db)
                let assetRecords = try AssetRecord.fetchAll(db)
                let eventRecords = try EventRecord.fetchAll(db)
                let decisionRecords = try DecisionRecord.order(Column("timestamp")).fetchAll(db)
                let compositionRecords = try MasterCompositionRecord.fetchAll(db)
                let compositionSectionRecords = try MasterCompositionSectionRecord.order(Column("position")).fetchAll(db)
                let selectionRecords = try MasterSelectionRecord.order(Column("selectedAt"), Column("kind"), Column("id")).fetchAll(db)

                var sectionsBySong: [UUID: [MasterSection]] = [:]
                for record in sectionRecords { sectionsBySong[record.songID, default: []].append(record.toDomain()) }
                var selectionsBySection: [UUID: [MasterSelection]] = [:]
                for record in selectionRecords {
                    guard let selection = record.toDomain() else { continue }
                    selectionsBySection[record.sectionID, default: []].append(selection)
                }
                var compositionSectionsByComposition: [UUID: [MasterCompositionSection]] = [:]
                for record in compositionSectionRecords {
                    compositionSectionsByComposition[record.compositionID, default: []].append(
                        record.toDomain(selections: selectionsBySection[record.id] ?? [])
                    )
                }

                let songs = songRecords.map { $0.toDomain(sections: sectionsBySong[$0.id] ?? []) }
                let masterCompositions = compositionRecords.map {
                    $0.toDomain(sections: compositionSectionsByComposition[$0.id] ?? [])
                }
                return ArtistCatalog(
                    artistName: artistName,
                    songs: songs,
                    assets: assetRecords.map { $0.toDomain() },
                    events: eventRecords.map { $0.toDomain() },
                    decisions: decisionRecords.map { $0.toDomain() },
                    masterCompositions: masterCompositions
                )
            }
        } catch {
            logger.error("Failed to load catalog: \(error.localizedDescription)")
            return ArtistCatalog(artistName: artistName, songs: [], assets: [], events: [], decisions: [], masterCompositions: [])
        }
    }

    func upsert(song: Song) throws {
        try database.dbQueue.write { db in try saveSong(song, in: db) }
    }

    func upsert(masterComposition: MasterComposition) throws {
        try database.dbQueue.write { db in try replaceMasterComposition(masterComposition, in: db) }
    }

    func commitSongCompatibilityMirror(
        song: Song,
        syncChanges: [SyncLogic.JSONDict] = []
    ) throws {
        try database.dbQueue.write { db in
            try saveSong(song, in: db)
            try enqueueCanonicalSyncChanges(syncChanges, in: db)
        }
    }

    func commitMasterAnnotation(
        song: Song,
        masterComposition: MasterComposition,
        syncChanges: [SyncLogic.JSONDict] = []
    ) throws {
        try database.dbQueue.write { db in
            try saveSong(song, in: db)
            try replaceMasterComposition(masterComposition, in: db)
            try enqueueCanonicalSyncChanges(syncChanges, in: db)
        }
    }

    /// Persists an automatically observed decision escalation without creating
    /// an artist-intent Decision. The canonical state, compatibility Song mirror,
    /// factual Events, and outbound sync intent share one transaction.
    func commitAutoDecisionEscalation(
        song: Song,
        events: [CreativeEvent],
        masterComposition: MasterComposition,
        syncChanges: [SyncLogic.JSONDict] = []
    ) throws {
        try database.dbQueue.write { db in
            try saveSong(song, in: db)
            for event in events { try EventRecord(event).save(db) }
            try replaceMasterComposition(masterComposition, in: db)
            try enqueueCanonicalSyncChanges(syncChanges, in: db)
        }
    }

    func commitApproval(
        song: Song,
        events: [CreativeEvent],
        decision: CreativeDecision,
        masterComposition: MasterComposition,
        syncChanges: [SyncLogic.JSONDict] = []
    ) throws {
        try database.dbQueue.write { db in
            try saveSong(song, in: db)
            for event in events { try EventRecord(event).save(db) }
            try DecisionRecord(decision).save(db)
            try replaceMasterComposition(masterComposition, in: db)
            try enqueueCanonicalSyncChanges(syncChanges, in: db)
        }
    }

    /// Persists one filename-intelligence mutation as a single unit so ownership
    /// metadata can never move without its factual history and durable sync intent.
    func commitFilenameReanalysis(
        asset: Asset,
        createdSong: Song? = nil,
        events: [CreativeEvent] = [],
        syncChanges: [SyncLogic.JSONDict] = []
    ) throws {
        try database.dbQueue.write { db in
            if let createdSong { try saveSong(createdSong, in: db) }
            try AssetRecord(asset).save(db)
            for event in events { try EventRecord(event).save(db) }
            try enqueueCanonicalSyncChanges(syncChanges, in: db)
        }
    }

    func persistCanonicalSync(_ applied: [CanonicalSync.AppliedChange], catalog: ArtistCatalog) throws {
        try database.dbQueue.write { db in
            for change in applied {
                switch change.kind {
                case .song:
                    if change.deleted {
                        try AssetRecord.filter(Column("songID") == change.id).deleteAll(db)
                        try SongRecord.filter(Column("id") == change.id).deleteAll(db)
                    } else if let song = catalog.songs.first(where: { $0.id == change.id }) {
                        try saveSong(song, in: db)
                    }
                case .asset:
                    if change.deleted { try AssetRecord.filter(Column("id") == change.id).deleteAll(db) }
                    else if let asset = catalog.assets.first(where: { $0.id == change.id }) { try AssetRecord(asset).save(db) }
                case .event:
                    if change.deleted { try EventRecord.filter(Column("id") == change.id).deleteAll(db) }
                    else if let event = catalog.events.first(where: { $0.id == change.id }) { try EventRecord(event).save(db) }
                case .decision:
                    if change.deleted { try DecisionRecord.filter(Column("id") == change.id).deleteAll(db) }
                    else if let decision = catalog.decisions.first(where: { $0.id == change.id }) { try DecisionRecord(decision).save(db) }
                case .masterComposition:
                    if change.deleted { try MasterCompositionRecord.filter(Column("id") == change.id).deleteAll(db) }
                    else if let composition = catalog.masterCompositions.first(where: { $0.id == change.id }) { try replaceMasterComposition(composition, in: db) }
                }
            }
        }
    }

    // MARK: - Durable canonical sync outbox

    func enqueueCanonicalSyncChanges(_ changes: [SyncLogic.JSONDict]) throws {
        try database.dbQueue.write { db in
            try enqueueCanonicalSyncChanges(changes, in: db)
        }
    }

    func canonicalSyncOutbox() throws -> [CanonicalSyncOutboxItem] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, payload FROM canonicalSyncOutbox ORDER BY updatedAt, key")
            return try rows.map { row in
                let key: String = row["key"]
                let payload: Data = row["payload"]
                guard let change = try JSONSerialization.jsonObject(with: payload) as? SyncLogic.JSONDict else {
                    throw CanonicalSyncOutboxError.invalidStoredPayload
                }
                return CanonicalSyncOutboxItem(key: key, payload: payload, change: change)
            }
        }
    }

    func removeCanonicalSyncOutbox(_ acknowledged: [CanonicalSyncOutboxItem]) throws {
        guard !acknowledged.isEmpty else { return }
        try database.dbQueue.write { db in
            for item in acknowledged {
                try db.execute(
                    sql: "DELETE FROM canonicalSyncOutbox WHERE key = ? AND payload = ?",
                    arguments: [item.key, item.payload]
                )
            }
        }
    }

    private func enqueueCanonicalSyncChanges(_ changes: [SyncLogic.JSONDict], in db: Database) throws {
        for change in changes {
            guard let kind = change["kind"] as? String, !kind.isEmpty else {
                throw CanonicalSyncOutboxError.missingKind
            }
            guard let entityID = change["id"] as? String, !entityID.isEmpty else {
                throw CanonicalSyncOutboxError.missingEntityID
            }
            guard let updatedAtNumber = change["updatedAt"] as? NSNumber,
                  updatedAtNumber.doubleValue.isFinite else {
                throw CanonicalSyncOutboxError.invalidUpdatedAt
            }
            guard JSONSerialization.isValidJSONObject(change) else {
                throw CanonicalSyncOutboxError.invalidJSONObject
            }

            let updatedAt = updatedAtNumber.doubleValue
            let payload = try JSONSerialization.data(withJSONObject: change)
            let key = "\(kind):\(entityID)"
            try db.execute(
                sql: """
                INSERT INTO canonicalSyncOutbox (key, kind, entityID, updatedAt, payload)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                  kind = excluded.kind,
                  entityID = excluded.entityID,
                  updatedAt = excluded.updatedAt,
                  payload = excluded.payload
                WHERE excluded.updatedAt >= canonicalSyncOutbox.updatedAt
                """,
                arguments: [key, kind, entityID, updatedAt, payload]
            )
        }
    }

    private func saveSong(_ song: Song, in db: Database) throws {
        try SongRecord(song).save(db)
        try SectionRecord.filter(Column("songID") == song.id).deleteAll(db)
        for (index, section) in song.sections.enumerated() { try SectionRecord(section, songID: song.id, position: index).save(db) }
    }

    private func replaceMasterComposition(_ masterComposition: MasterComposition, in db: Database) throws {
        try MasterCompositionRecord.filter(Column("songID") == masterComposition.songID).deleteAll(db)
        try MasterCompositionRecord(masterComposition).save(db)
        for (position, section) in masterComposition.sections.enumerated() {
            try MasterCompositionSectionRecord(section, compositionID: masterComposition.id, position: position).save(db)
            for selection in section.selections { try MasterSelectionRecord(selection, sectionID: section.id).save(db) }
        }
    }

    func delete(songID: UUID) throws {
        _ = try database.dbQueue.write { db in
            try AssetRecord.filter(Column("songID") == songID).deleteAll(db)
            try SongRecord.filter(Column("id") == songID).deleteAll(db)
        }
    }

    func insert(asset: Asset) throws { try database.dbQueue.write { db in try AssetRecord(asset).save(db) } }
    func append(event: CreativeEvent) throws { try database.dbQueue.write { db in try EventRecord(event).save(db) } }
    func append(decision: CreativeDecision) throws { try database.dbQueue.write { db in try DecisionRecord(decision).save(db) } }

    func delete(assetID: UUID) throws { _ = try database.dbQueue.write { db in try AssetRecord.filter(Column("id") == assetID).deleteAll(db) } }
    func delete(eventID: UUID) throws { _ = try database.dbQueue.write { db in try EventRecord.filter(Column("id") == eventID).deleteAll(db) } }
    func delete(decisionID: UUID) throws { _ = try database.dbQueue.write { db in try DecisionRecord.filter(Column("id") == decisionID).deleteAll(db) } }
    func delete(masterCompositionID: UUID) throws { _ = try database.dbQueue.write { db in try MasterCompositionRecord.filter(Column("id") == masterCompositionID).deleteAll(db) } }

    func watchedFolders() -> [WatchedFolder] {
        (try? database.dbQueue.read { db in try WatchedFolderRecord.order(Column("addedAt")).fetchAll(db).map { $0.toDomain() }) ?? []
    }

    func save(watchedFolder: WatchedFolder) throws {
        try database.dbQueue.write { db in
            try WatchedFolderRecord.filter(Column("path") == watchedFolder.path).deleteAll(db)
            try WatchedFolderRecord(watchedFolder).save(db)
        }
    }

    func deleteWatchedFolder(id: UUID) throws {
        _ = try database.dbQueue.write { db in
            try WatchedFolderRecord.filter(Column("id") == id).deleteAll(db)
        }
    }

    func seed(_ catalog: ArtistCatalog) {
        do {
            try database.dbQueue.write { db in
                for song in catalog.songs { try saveSong(song, in: db) }
                for asset in catalog.assets { try AssetRecord(asset).save(db) }
                for event in catalog.events { try EventRecord(event).save(db) }
                for decision in catalog.decisions { try DecisionRecord(decision).save(db) }
                for composition in catalog.masterCompositions { try replaceMasterComposition(composition, in: db) }
            }
        } catch {
            logger.error("Failed to seed catalog: \(error.localizedDescription)")
        }
    }
}
