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
            state.catalog.masterCompositions.first?.sections[0].selection(.sourceAsset)?.decisionID,
            decision.id
        )

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.decisions.map(\.id), [decision.id])
        XCTAssertEqual(
            reloaded.masterCompositions.first?.sections[0].selection(.sourceAsset)?.referenceID,
            assetID
        )
    }

    func testCanonicalPullArchivesLegacySongTombstoneWithoutDestroyingEvidence() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var first = ImportService.makeSong(title: "First")
        first.updatedAt = Date(timeIntervalSince1970: 1_000)
        let second = ImportService.makeSong(title: "Second")
        try store.upsert(song: first)
        try store.upsert(song: second)

        let preservedAsset = Asset(
            id: UUID(),
            title: "First Song Mix",
            originalFilename: "first-mix.wav",
            role: .fullMix,
            createdAt: Date(),
            duration: 1,
            localURLBookmark: nil,
            songID: first.id
        )
        try store.insert(asset: preservedAsset)

        let preservedEvent = CreativeEvent(
            id: UUID(),
            songID: first.id,
            timestamp: Date(timeIntervalSince1970: 1_001),
            target: .song,
            operation: .imported,
            beforeAssetID: nil,
            afterAssetID: preservedAsset.id,
            summary: "Imported first song.",
            confidence: 1
        )
        try store.append(event: preservedEvent)

        let preservedDecision = CreativeDecision(
            id: UUID(),
            songID: first.id,
            timestamp: Date(timeIntervalSince1970: 1_002),
            target: .song,
            action: .approved,
            selectedAssetID: preservedAsset.id
        )
        try store.append(decision: preservedDecision)

        let preservedComposition = MasterComposition(
            songID: first.id,
            sections: [],
            outputAssetID: preservedAsset.id,
            updatedAt: Date(timeIntervalSince1970: 1_003)
        )
        try store.upsert(masterComposition: preservedComposition)

        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.selectedSongID = first.id

        let applied = try state.applyCanonicalCloudChanges([[
            "kind": "song",
            "id": first.id.uuidString,
            "updatedAt": 2_000_000.0,
            "deleted": true
        ]])

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.kind, .song)
        XCTAssertEqual(applied.first?.id, first.id)
        XCTAssertEqual(applied.first?.deleted, false)
        XCTAssertEqual(state.catalog.songs.first(where: { $0.id == first.id })?.status, .archived)
        XCTAssertTrue(state.catalog.assets.contains(where: { $0.id == preservedAsset.id }))
        XCTAssertTrue(state.catalog.events.contains(where: { $0.id == preservedEvent.id }))
        XCTAssertTrue(state.catalog.decisions.contains(where: { $0.id == preservedDecision.id }))
        XCTAssertEqual(state.catalog.masterComposition(for: first.id)?.id, preservedComposition.id)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs.first(where: { $0.id == first.id })?.status, .archived)
        XCTAssertTrue(reloaded.assets.contains(where: { $0.id == preservedAsset.id }))
        XCTAssertTrue(reloaded.events.contains(where: { $0.id == preservedEvent.id }))
        XCTAssertTrue(reloaded.decisions.contains(where: { $0.id == preservedDecision.id }))
        XCTAssertEqual(reloaded.masterComposition(for: first.id)?.id, preservedComposition.id)
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
