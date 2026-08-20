import XCTest
import ArtistOSCore
@testable import ArtistOS

final class FilenameReanalysisPersistenceTests: XCTestCase {
    func testFilenameRegroupCommitsAssetEventAndOutboxTogether() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let home = ImportService.makeSong(title: "Home")
        let target = ImportService.makeSong(title: "Target")
        try store.upsert(song: home)
        try store.upsert(song: target)

        var asset = Asset(
            id: UUID(),
            title: "Target v2.wav",
            originalFilename: "Target v2.wav",
            role: .reference,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: home.id
        )
        try store.insert(asset: asset)

        let timestamp = Date(timeIntervalSince1970: 2_000_000_300)
        asset.songID = target.id
        asset.updatedAt = timestamp
        let event = CreativeEvent(
            id: UUID(), songID: target.id, timestamp: timestamp,
            target: .song, operation: .imported,
            beforeAssetID: nil, afterAssetID: asset.id,
            summary: "Target v2.wav regrouped into song (re-analysis).",
            confidence: 1
        )
        let changes = [SyncLogic.change(forAsset: asset), SyncLogic.change(forEvent: event)]

        try store.commitFilenameReanalysis(
            asset: asset,
            events: [event],
            syncChanges: changes
        )

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.assets.first(where: { $0.id == asset.id })?.songID, target.id)
        XCTAssertEqual(loaded.events.map(\.id), [event.id])
        XCTAssertEqual(try store.canonicalSyncOutbox().count, 2)
    }

    func testInvalidOutboxPayloadRollsBackFilenameRegroupTransaction() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let home = ImportService.makeSong(title: "Home")
        let target = ImportService.makeSong(title: "Target")
        try store.upsert(song: home)
        try store.upsert(song: target)

        var asset = Asset(
            id: UUID(),
            title: "Target v2.wav",
            originalFilename: "Target v2.wav",
            role: .reference,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: home.id
        )
        try store.insert(asset: asset)

        let timestamp = Date(timeIntervalSince1970: 2_000_000_400)
        asset.songID = target.id
        asset.updatedAt = timestamp
        let event = CreativeEvent(
            id: UUID(), songID: target.id, timestamp: timestamp,
            target: .song, operation: .imported,
            beforeAssetID: nil, afterAssetID: asset.id,
            summary: "Must roll back.",
            confidence: 1
        )
        let malformed: SyncLogic.JSONDict = [
            "kind": "asset",
            "id": asset.id.uuidString,
            "data": ["reason": "missing timestamp"]
        ]

        XCTAssertThrowsError(try store.commitFilenameReanalysis(
            asset: asset,
            events: [event],
            syncChanges: [malformed]
        ))

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.assets.first(where: { $0.id == asset.id })?.songID, home.id)
        XCTAssertFalse(loaded.events.contains(where: { $0.id == event.id }))
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }
}
