import Foundation
import ArtistOSCore
import GRDB
import os

/// Write-through persistence layer. The in-memory `ArtistCatalog` remains the
/// UI's source of truth; every mutation is mirrored to SQLite through this store.
final class CatalogStore {
    private let database: AppDatabase
    private let logger = Logger(subsystem: "com.stickley.artistos", category: "CatalogStore")

    init(database: AppDatabase) {
        self.database = database
    }

    /// Opens the shared on-disk database, falling back to in-memory if the
    /// disk store cannot be created (never crashes the app on launch).
    static func makeDefault() -> CatalogStore {
        do {
            return CatalogStore(database: try AppDatabase.shared())
        } catch {
            Logger(subsystem: "com.stickley.artistos", category: "CatalogStore")
                .error("Falling back to in-memory database: \(error.localizedDescription)")
            // In-memory DatabaseQueue cannot fail to open.
            return CatalogStore(database: try! AppDatabase.inMemory())
        }
    }

    // MARK: - Load

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
                let sectionRecords = try SectionRecord
                    .order(Column("position"))
                    .fetchAll(db)
                let assetRecords = try AssetRecord.fetchAll(db)
                let eventRecords = try EventRecord.fetchAll(db)
                let decisionRecords = try DecisionRecord
                    .order(Column("timestamp"))
                    .fetchAll(db)
                let compositionRecords = try MasterCompositionRecord.fetchAll(db)
                let compositionSectionRecords = try MasterCompositionSectionRecord
                    .order(Column("position"))
                    .fetchAll(db)
                let selectionRecords = try MasterSelectionRecord
                    .order(Column("selectedAt"))
                    .fetchAll(db)

                var sectionsBySong: [UUID: [MasterSection]] = [:]
                for record in sectionRecords {
                    sectionsBySong[record.songID, default: []].append(record.toDomain())
                }

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
            return ArtistCatalog(
                artistName: artistName,
                songs: [],
                assets: [],
                events: [],
                decisions: [],
                masterCompositions: []
            )
        }
    }

    // MARK: - Write

    func upsert(song: Song) throws {
        try database.dbQueue.write { db in
            try SongRecord(song).save(db)
            try SectionRecord.filter(Column("songID") == song.id).deleteAll(db)
            for (index, section) in song.sections.enumerated() {
                try SectionRecord(section, songID: song.id, position: index).save(db)
            }
        }
    }

    /// Persists the canonical composition as one atomic replacement. Existing
    /// legacy Song.sections are deliberately untouched during migration.
    func upsert(masterComposition: MasterComposition) throws {
        try database.dbQueue.write { db in
            // songID is unique; deleting first also safely handles a future
            // persisted composition ID that differs from the legacy song ID.
            try MasterCompositionRecord
                .filter(Column("songID") == masterComposition.songID)
                .deleteAll(db)
            try MasterCompositionRecord(masterComposition).save(db)

            for (position, section) in masterComposition.sections.enumerated() {
                try MasterCompositionSectionRecord(
                    section,
                    compositionID: masterComposition.id,
                    position: position
                ).save(db)
                for selection in section.selections {
                    try MasterSelectionRecord(selection, sectionID: section.id).save(db)
                }
            }
        }
    }

    func delete(songID: UUID) throws {
        _ = try database.dbQueue.write { db in
            try AssetRecord.filter(Column("songID") == songID).deleteAll(db)
            try SongRecord.filter(Column("id") == songID).deleteAll(db)
        }
    }

    func insert(asset: Asset) throws {
        try database.dbQueue.write { db in
            try AssetRecord(asset).save(db)
        }
    }

    func append(event: CreativeEvent) throws {
        try database.dbQueue.write { db in
            try EventRecord(event).save(db)
        }
    }

    func append(decision: CreativeDecision) throws {
        try database.dbQueue.write { db in
            try DecisionRecord(decision).save(db)
        }
    }

    // MARK: - Watched folders

    func watchedFolders() -> [WatchedFolder] {
        (try? database.dbQueue.read { db in
            try WatchedFolderRecord.order(Column("addedAt")).fetchAll(db).map { $0.toDomain() }
        }) ?? []
    }

    func save(watchedFolder: WatchedFolder) throws {
        try database.dbQueue.write { db in
            // Unique on path: replace an existing entry for the same folder.
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
                for song in catalog.songs {
                    try SongRecord(song).save(db)
                    for (index, section) in song.sections.enumerated() {
                        try SectionRecord(section, songID: song.id, position: index).save(db)
                    }
                }
                for asset in catalog.assets {
                    try AssetRecord(asset).save(db)
                }
                for event in catalog.events {
                    try EventRecord(event).save(db)
                }
                for decision in catalog.decisions {
                    try DecisionRecord(decision).save(db)
                }
                for composition in catalog.masterCompositions {
                    try MasterCompositionRecord(composition).save(db)
                    for (position, section) in composition.sections.enumerated() {
                        try MasterCompositionSectionRecord(
                            section,
                            compositionID: composition.id,
                            position: position
                        ).save(db)
                        for selection in section.selections {
                            try MasterSelectionRecord(selection, sectionID: section.id).save(db)
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to seed catalog: \(error.localizedDescription)")
        }
    }
}
