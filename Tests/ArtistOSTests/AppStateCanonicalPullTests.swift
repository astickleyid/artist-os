import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class AppStateCanonicalPullTests: XCTestCase {
    func testCanonicalPullAppliesDecisionAndMasterCompositionAndPersistsThem() throws {
        let database = try AppDatabase.inMemory()
        let store = CatalogStore(database: database)
        let song = ImportService.makeSong(title: "Canonical Pull")
        try store.upsert(song: song)

        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        let timestamp = Date(timeIntervalSince1970: 1_787_000_000)
        let assetID = UUID()
        let decision = CreativeDecision(
            id: UUID(),
            songID: song.id,
            timestamp: timestamp,
            target: .hook,
            action: .approved,
            selectedAssetID: assetID,
            rejectedAssetIDs: [],
            relatedEventIDs: [],
            reason: "Best emotional read",
            source: .artist
        )
        var composition = MasterComposition.projected(from: song)
        composition.sections[0].setSelection(MasterSelection(
            kind: .sourceAsset,
            referenceID: assetID,
            decisionID: decision.id,
            selectedAt: timestamp
        ))
        composition.updatedAt = timestamp

        let applied = try state.applyCanonicalCloudChanges([
            SyncLogic.change(forDecision: decision),
            SyncLogic.change(forMasterComposition: composition)
        ])

        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(state.catalog.decisions.map(\.id), [decision.id])
        XCTAssertEqual(
            state.catalog.masterCompositions.first?.sections[0].selection(of: .sourceAsset)?.decisionID,
            decision.id
        )

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.decisions.map(\.id), [decision.id])
        XCTAssertEqual(
            reloaded.masterCompositions.first?.sections[0].selection(of: .sourceAsset)?.referenceID,
            assetID
        )
    }

    func testCanonicalPullRepairsSelectionAfterRemoteSongTombstone() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let first = ImportService.makeSong(title: "First")
        let second = ImportService.makeSong(title: "Second")
        try store.upsert(song: first)
        try store.upsert(song: second)

        let asset = Asset(
            id: UUID(),
            title: "Selected",
            originalFilename: "selected.wav",
            role: .fullMix,
            createdAt: Date(),
            duration: 1,
            localURLBookmark: nil,
            songID: first.id
        )
        try store.insert(asset: asset)

        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.selectedSongID = first.id
        state.selectedAssetID = asset.id

        let applied = try state.applyCanonicalCloudChanges([
            SyncLogic.tombstone(kindRaw: "song", id: first.id.uuidString)
        ])

        XCTAssertEqual(applied.count, 1)
        XCTAssertFalse(state.catalog.songs.contains(where: { $0.id == first.id }))
        XCTAssertFalse(state.catalog.assets.contains(where: { $0.id == asset.id }))
        XCTAssertEqual(state.selectedSongID, second.id)
        XCTAssertNil(state.selectedAssetID)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertFalse(reloaded.songs.contains(where: { $0.id == first.id }))
        XCTAssertFalse(reloaded.assets.contains(where: { $0.id == asset.id }))
    }

    func testCanonicalPullRejectsStaleCompositionWithoutMutatingSelection() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Stale")
        try store.upsert(song: song)

        var current = MasterComposition.projected(from: song)
        current.updatedAt = Date(timeIntervalSince1970: 2_000)
        try store.upsert(masterComposition: current)

        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.selectedSongID = song.id

        var stale = current
        stale.outputAssetID = UUID()
        stale.updatedAt = Date(timeIntervalSince1970: 1_000)

        let applied = try state.applyCanonicalCloudChanges([
            SyncLogic.change(forMasterComposition: stale)
        ])

        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(state.catalog.masterCompositions.first?.outputAssetID, current.outputAssetID)
        XCTAssertEqual(state.selectedSongID, song.id)
    }
}
