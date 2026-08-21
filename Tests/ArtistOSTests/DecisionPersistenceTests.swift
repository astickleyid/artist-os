import XCTest
import ArtistOSCore
@testable import ArtistOS

final class DecisionPersistenceTests: XCTestCase {
    private func assertDecisionEqual(
        _ actual: CreativeDecision,
        _ expected: CreativeDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.songID, expected.songID, file: file, line: line)
        XCTAssertEqual(actual.timestamp.timeIntervalSince1970,
                       expected.timestamp.timeIntervalSince1970,
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.target, expected.target, file: file, line: line)
        XCTAssertEqual(actual.action, expected.action, file: file, line: line)
        XCTAssertEqual(actual.selectedAssetID, expected.selectedAssetID, file: file, line: line)
        XCTAssertEqual(actual.rejectedAssetIDs, expected.rejectedAssetIDs, file: file, line: line)
        XCTAssertEqual(actual.relatedEventIDs, expected.relatedEventIDs, file: file, line: line)
        XCTAssertEqual(actual.reason, expected.reason, file: file, line: line)
        XCTAssertEqual(actual.source, expected.source, file: file, line: line)
    }

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
        assertDecisionEqual(loaded.decisions[0], decision)
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
        XCTAssertEqual(loaded.decisions.count, 1)
        assertDecisionEqual(loaded.decisions[0], decision)
    }
}
