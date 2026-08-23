import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class SongLifecyclePersistenceTests: XCTestCase {
    func testArchivePersistsStatusAndFactWithoutDestroyingCreativeState() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Permanent Song")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)

        let asset = Asset(
            id: UUID(), title: "Hook Take", originalFilename: "hook.wav", role: .hook,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: Date(), target: .hook,
            action: .selected, selectedAssetID: asset.id,
            reason: "Best emotional take", source: .artist
        )
        state.catalog.decisions.append(decision)
        try store.append(decision: decision)

        var composition = try XCTUnwrap(state.catalog.masterComposition(for: songID))
        composition.outputAssetID = asset.id
        composition.updatedAt = Date()
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        let eventCountBefore = state.catalog.events.count
        state.archiveSong(id: songID)

        XCTAssertEqual(state.catalog.songs.first?.status, .archived)
        XCTAssertEqual(state.catalog.assets.map(\.id), [asset.id])
        XCTAssertEqual(state.catalog.decisions.map(\.id), [decision.id])
        XCTAssertEqual(state.catalog.masterComposition(for: songID)?.outputAssetID, asset.id)
        XCTAssertEqual(state.catalog.events.count, eventCountBefore + 1)
        XCTAssertEqual(state.catalog.events.last?.operation, .archived)

        let reloaded = store.loadCatalog(artistName: "Test")
        XCTAssertEqual(reloaded.songs.first?.id, songID)
        XCTAssertEqual(reloaded.songs.first?.status, .archived)
        XCTAssertEqual(reloaded.assets.map(\.id), [asset.id])
        XCTAssertEqual(reloaded.decisions.map(\.id), [decision.id])
        XCTAssertEqual(reloaded.masterComposition(for: songID)?.outputAssetID, asset.id)
        XCTAssertEqual(reloaded.events.last?.operation, .archived)
    }

    func testArchivingSelectedSongRepairsSelectionToActiveSong() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Keep Active")
        let activeID = try XCTUnwrap(state.selectedSongID)
        state.createSong(title: "Archive Me")
        let archivedID = try XCTUnwrap(state.selectedSongID)
        XCTAssertNotEqual(activeID, archivedID)

        state.archiveSong(id: archivedID)

        XCTAssertEqual(state.catalog.songs.first(where: { $0.id == archivedID })?.status, .archived)
        XCTAssertEqual(state.selectedSongID, activeID)
        XCTAssertNil(state.selectedAssetID)
    }

    func testRestoreKeepsSameSongAndAddsFactualLifecycleEvent() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Return Me")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)

        state.archiveSong(id: songID)
        let archivedEventCount = state.catalog.events.count
        state.restoreSong(id: songID, to: .review)

        XCTAssertEqual(state.catalog.songs.first?.id, songID)
        XCTAssertEqual(state.catalog.songs.first?.status, .review)
        XCTAssertEqual(state.catalog.events.count, archivedEventCount + 1)
        XCTAssertTrue(state.catalog.events.last?.summary.contains("restored") ?? false)

        let reloaded = store.loadCatalog(artistName: "Test")
        XCTAssertEqual(reloaded.songs.first?.id, songID)
        XCTAssertEqual(reloaded.songs.first?.status, .review)
        XCTAssertTrue(reloaded.events.last?.summary.contains("restored") ?? false)
    }

    func testLifecyclePersistenceRollsBackWhenOutboxChangeIsInvalid() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let original = ImportService.makeSong(title: "Rollback")
        try store.upsert(song: original)

        let timestamp = Date()
        let archived = SongLifecycle.archive(original, at: timestamp)
        let event = CreativeEvent(
            id: UUID(), songID: original.id, timestamp: timestamp, target: .song,
            operation: .archived, beforeAssetID: nil, afterAssetID: nil,
            summary: "Rollback archived.", confidence: 1
        )
        let invalidChange: SyncLogic.JSONDict = [
            "kind": "song",
            "id": original.id.uuidString,
            "updatedAt": Double.nan
        ]

        XCTAssertThrowsError(
            try store.commitSongLifecycle(song: archived, event: event, syncChanges: [invalidChange])
        )

        let reloaded = store.loadCatalog(artistName: "Test")
        XCTAssertEqual(reloaded.songs.first?.status, original.status)
        XCTAssertTrue(reloaded.events.isEmpty)
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }

    func testDestructiveSongDeletionIsRetiredAndPreservesPersistentHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Keep Forever")
        try store.upsert(song: song)

        let asset = Asset(
            id: UUID(), title: "Master", originalFilename: "master.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        try store.insert(asset: asset)

        XCTAssertThrowsError(try store.delete(songID: song.id)) { error in
            XCTAssertEqual(error as? RetiredSongDeletionError, .destructiveDeletionRetired)
        }

        let reloaded = store.loadCatalog(artistName: "Test")
        XCTAssertEqual(reloaded.songs.map(\.id), [song.id])
        XCTAssertEqual(reloaded.assets.map(\.id), [asset.id])
    }
}
