import XCTest
import ArtistOSCore
@testable import ArtistOS

final class DecisionPersistenceTests: XCTestCase {
    func testDecisionRoundTripPreservesIntent() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Decision Round Trip")
        try store.upsert(song: song)

        let selected = Asset(
            id: UUID(), title: "Hook B", originalFilename: "hook-b.wav", role: .hook,
            createdAt: Date(), duration: 18, localURLBookmark: nil, songID: song.id
        )
        let rejected = Asset(
            id: UUID(), title: "Hook A", originalFilename: "hook-a.wav", role: .hook,
            createdAt: Date(), duration: 18, localURLBookmark: nil, songID: song.id
        )
        try store.insert(asset: selected)
        try store.insert(asset: rejected)

        let eventID = UUID()
        try store.append(event: CreativeEvent(
            id: eventID,
            songID: song.id,
            timestamp: Date(),
            target: .hook,
            operation: .sourceSelected,
            beforeAssetID: rejected.id,
            afterAssetID: selected.id,
            summary: "Hook source changed from A to B.",
            confidence: 1
        ))

        let decision = CreativeDecision(
            id: UUID(),
            songID: song.id,
            timestamp: Date(),
            target: .hook,
            action: .selected,
            selectedAssetID: selected.id,
            rejectedAssetIDs: [rejected.id],
            relatedEventIDs: [eventID],
            reason: "B carries the emotion better in the second half.",
            source: .artist
        )
        try store.append(decision: decision)

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.decisions.count, 1)
        XCTAssertEqual(loaded.decisions[0], decision)
        XCTAssertEqual(loaded.decisions[0].selectedAssetID, selected.id)
        XCTAssertEqual(loaded.decisions[0].rejectedAssetIDs, [rejected.id])
        XCTAssertEqual(loaded.decisions[0].relatedEventIDs, [eventID])
        XCTAssertEqual(loaded.decisions[0].reason, "B carries the emotion better in the second half.")
    }

    func testDeletingSongCascadesDecisionHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Decision Cascade")
        try store.upsert(song: song)
        try store.append(decision: CreativeDecision(
            id: UUID(),
            songID: song.id,
            timestamp: Date(),
            target: .song,
            action: .deferred,
            selectedAssetID: nil,
            reason: "Revisit after the next recording session."
        ))

        try store.delete(songID: song.id)

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertTrue(loaded.songs.isEmpty)
        XCTAssertTrue(loaded.decisions.isEmpty)
    }

    func testSeedIncludesDecisionHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Seeded")
        let decision = CreativeDecision(
            id: UUID(),
            songID: song.id,
            timestamp: Date(),
            target: .master,
            action: .approved,
            selectedAssetID: nil,
            reason: "Structure is approved for the next mix pass."
        )
        store.seed(ArtistCatalog(
            artistName: "T",
            songs: [song],
            assets: [],
            events: [],
            decisions: [decision]
        ))

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.decisions, [decision])
    }
}
