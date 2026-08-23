import Foundation
import GRDB

/// Owns the SQLite connection and schema migrations.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    /// Production database at ~/Library/Application Support/ArtistOS/catalog.sqlite
    static func shared() throws -> AppDatabase {
        let fm = FileManager.default
        let dir = try fm
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ArtistOS", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(
            path: dir.appendingPathComponent("catalog.sqlite").path,
            configuration: config
        )
        return try AppDatabase(queue)
    }

    /// In-memory database for tests and as a safe fallback.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// Materializes first-class canonical Master Composition rows from the
    /// legacy Song/section mirror only when a Song has no persisted canonical
    /// composition yet. This is intentionally idempotent so migration tests can
    /// exercise it directly and existing canonical truth is never overwritten.
    static func materializeLegacyMasterCompositions(in db: Database) throws {
        let songs = try Row.fetchAll(
            db,
            sql: """
            SELECT id, masterAssetID, updatedAt
            FROM song
            WHERE NOT EXISTS (
                SELECT 1 FROM masterComposition
                WHERE masterComposition.songID = song.id
            )
            """
        )

        for song in songs {
            let songID: String = song["id"]
            let outputAssetID: String? = song["masterAssetID"]
            let storedUpdatedAt: Date? = song["updatedAt"]
            let updatedAt = storedUpdatedAt ?? Date(timeIntervalSince1970: 0)

            // Reuse the permanent Song ID as the canonical composition ID. This
            // matches MasterComposition.projected(from:) and keeps migration
            // identity deterministic across direct upgrades and repeated tests.
            try db.execute(
                sql: """
                INSERT INTO masterComposition (id, songID, outputAssetID, updatedAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [songID, songID, outputAssetID, updatedAt]
            )

            let sections = try Row.fetchAll(
                db,
                sql: """
                SELECT id, position, name, role, assetID, state, confidence, note
                FROM section
                WHERE songID = ?
                ORDER BY position
                """,
                arguments: [songID]
            )

            for section in sections {
                let sectionID: String = section["id"]
                let position: Int = section["position"]
                let name: String = section["name"]
                let role: String = section["role"]
                let sourceAssetID: String? = section["assetID"]
                let state: String = section["state"]
                let confidence: Double = section["confidence"]
                let note: String = section["note"]

                try db.execute(
                    sql: """
                    INSERT INTO masterCompositionSection
                        (id, compositionID, position, name, role, state, confidence, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        sectionID, songID, position, name, role,
                        state, confidence, note
                    ]
                )

                guard let sourceAssetID else { continue }

                // A legacy section can contain at most one source binding, so its
                // stable section ID is also a deterministic selection ID. The two
                // IDs live in different tables and therefore cannot collide.
                try db.execute(
                    sql: """
                    INSERT INTO masterSelection
                        (id, sectionID, kind, referenceID, decisionID, selectedAt)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    """,
                    arguments: [
                        sectionID, sectionID, "Source Asset", sourceAssetID, updatedAt
                    ]
                )
            }
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "song") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("era", .text).notNull()
                t.column("status", .text).notNull()
                t.column("progress", .double).notNull()
                t.column("qualityScore", .double).notNull()
                t.column("risk", .text).notNull()
            }

            try db.create(table: "section") { t in
                t.column("id", .text).primaryKey()
                t.column("songID", .text).notNull().indexed()
                    .references("song", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("role", .text).notNull()
                t.column("assetID", .text)
                t.column("state", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("note", .text).notNull()
            }

            try db.create(table: "asset") { t in
                t.column("id", .text).primaryKey()
                t.column("songID", .text).indexed()
                t.column("title", .text).notNull()
                t.column("originalFilename", .text).notNull()
                t.column("role", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("duration", .double)
                t.column("localURLBookmark", .blob)
                t.column("sourcePath", .text)
                t.column("fileSize", .integer)
                t.column("format", .text)
                t.column("sampleRate", .double)
                t.column("channels", .integer)
            }

            try db.create(table: "event") { t in
                t.column("id", .text).primaryKey()
                t.column("songID", .text).notNull().indexed()
                    .references("song", onDelete: .cascade)
                t.column("timestamp", .datetime).notNull()
                t.column("target", .text).notNull()
                t.column("operation", .text).notNull()
                t.column("beforeAssetID", .text)
                t.column("afterAssetID", .text)
                t.column("summary", .text).notNull()
                t.column("confidence", .double).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "contentHash", .text)
            }
            try db.create(index: "asset_contentHash", on: "asset", columns: ["contentHash"])

            try db.create(table: "watchedFolder") { t in
                t.column("id", .text).primaryKey()
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob)
                t.column("addedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "fileModifiedAt", .datetime)
            }
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "version", .text)
                t.add(column: "vOrder", .integer)
            }
            try db.alter(table: "song") { t in
                t.add(column: "masterAssetID", .text)
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "bpm", .double)
                t.add(column: "musicalKey", .text)
                t.add(column: "analyzedAt", .datetime)
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "song") { t in
                t.add(column: "updatedAt", .datetime)
            }
            try db.alter(table: "asset") { t in
                t.add(column: "updatedAt", .datetime)
                t.add(column: "cloudKey", .text)
            }
        }

        // Decisions are intentionally separate from factual CreativeEvents.
        // Events answer WHAT happened; decisions preserve WHY the current state exists.
        migrator.registerMigration("v7") { db in
            try db.create(table: "decision") { t in
                t.column("id", .text).primaryKey()
                t.column("songID", .text).notNull().indexed()
                    .references("song", onDelete: .cascade)
                t.column("timestamp", .datetime).notNull()
                t.column("target", .text).notNull()
                t.column("action", .text).notNull()
                t.column("selectedAssetID", .text)
                t.column("rejectedAssetIDs", .text).notNull()
                t.column("relatedEventIDs", .text).notNull()
                t.column("reason", .text)
                t.column("source", .text).notNull()
            }
        }

        // The canonical Master Composition is persisted independently from the
        // legacy Song.sections representation. One composition belongs to one Song;
        // sections and typed selections cascade with it. `referenceID` is not an
        // asset FK because processing/automation/comp references are intentionally
        // extensible immutable snapshot IDs.
        migrator.registerMigration("v8") { db in
            try db.create(table: "masterComposition") { t in
                t.column("id", .text).primaryKey()
                t.column("songID", .text).notNull().unique().indexed()
                    .references("song", onDelete: .cascade)
                t.column("outputAssetID", .text)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "masterCompositionSection") { t in
                t.column("id", .text).primaryKey()
                t.column("compositionID", .text).notNull().indexed()
                    .references("masterComposition", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("role", .text).notNull()
                t.column("state", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("note", .text).notNull()
            }

            try db.create(table: "masterSelection") { t in
                t.column("id", .text).primaryKey()
                t.column("sectionID", .text).notNull().indexed()
                    .references("masterCompositionSection", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("referenceID", .text).notNull()
                t.column("decisionID", .text)
                t.column("selectedAt", .datetime).notNull()
            }
            try db.create(
                index: "masterSelection_section_kind",
                on: "masterSelection",
                columns: ["sectionID", "kind"],
                unique: true
            )
        }

        // Canonical cloud delivery must survive process death. The outbox stores
        // the exact wire change, coalesced by entity identity. A newer local write
        // replaces an older unsent write for the same kind:id while preserving
        // tombstones and all five canonical entity kinds.
        migrator.registerMigration("v9") { db in
            try db.create(table: "canonicalSyncOutbox") { t in
                t.column("key", .text).primaryKey()
                t.column("kind", .text).notNull().indexed()
                t.column("entityID", .text).notNull()
                t.column("updatedAt", .double).notNull()
                t.column("payload", .blob).notNull()
            }
        }

        // Direct upgrades must preserve legacy source/master truth before the
        // compatibility columns are removed. Materialize a canonical composition
        // for every Song that does not already have one; existing canonical rows
        // always win and are never overwritten by legacy mirrors.
        migrator.registerMigration("v10") { db in
            try Self.materializeLegacyMasterCompositions(in: db)
        }

        return migrator
    }
}
