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

        return migrator
    }
}
