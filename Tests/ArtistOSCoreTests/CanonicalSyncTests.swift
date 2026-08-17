import XCTest
@testable import ArtistOSCore

final class CanonicalSyncTests: XCTestCase {
    func testAppliesDecisionMasterCompositionAndEventEvidence() throws {
        let songID = UUID()
        let assetA = UUID()
        let assetB = UUID()
        let eventID = UUID()
        let decisionID = UUID()
        let compositionID = UUID()
        let sectionID = UUID()
        let now = Date()

        var catalog = ArtistCatalog(
            artistName: "Stick",
            songs: [Song(
                id: songID, title: "Golden State", era: "2026", status: .review,
                progress: 0, qualityScore: 0, risk: "low", sections: [], updatedAt: now.addingTimeInterval(-10)
            )],
            assets: [],
            events: []
        )

        let event = CreativeEvent(
            id: eventID, songID: songID, timestamp: now,
            target: .hook, operation: .recordingUpdated,
            beforeAssetID: assetA, afterAssetID: assetB,
            summary: "Hook recording changed.", confidence: 1
        )
        let decision = CreativeDecision(
            id: decisionID, songID: songID, timestamp: now.addingTimeInterval(1),
            target: .hook, action: .selected, selectedAssetID: assetB,
            rejectedAssetIDs: [assetA], relatedEventIDs: [eventID],
            reason: "Better delivery", source: .artist
        )
        let composition = MasterComposition(
            id: compositionID,
            songID: songID,
            sections: [MasterCompositionSection(
                id: sectionID,
                name: "Hook",
                role: "Hook",
                selections: [MasterSelection(
                    kind: .sourceAsset,
                    referenceID: assetB,
                    decisionID: decisionID,
                    selectedAt: now.addingTimeInterval(1)
                )],
                state: .locked,
                confidence: 1
            )],
            outputAssetID: assetB,
            updatedAt: now.addingTimeInterval(2)
        )

        let applied = CanonicalSync.apply(changes: [
            SyncLogic.change(forEvent: event),
            SyncLogic.change(forDecision: decision),
            SyncLogic.change(forMasterComposition: composition)
        ], to: &catalog)

        XCTAssertEqual(applied.map(\.kind), [.event, .decision, .masterComposition])
        XCTAssertEqual(catalog.events.first?.beforeAssetID, assetA)
        XCTAssertEqual(catalog.events.first?.afterAssetID, assetB)
        XCTAssertEqual(catalog.decisions.first, decision)
        XCTAssertEqual(catalog.masterComposition(for: songID), composition)
        XCTAssertEqual(
            catalog.masterComposition(for: songID)?.sections.first?.selection(.sourceAsset)?.decisionID,
            decisionID
        )
    }

    func testRejectsOlderCanonicalStateAndAcceptsNewerState() {
        let songID = UUID()
        let compositionID = UUID()
        let oldAsset = UUID()
        let newerAsset = UUID()
        let baseline = Date()
        let local = MasterComposition(
            id: compositionID,
            songID: songID,
            sections: [],
            outputAssetID: oldAsset,
            updatedAt: baseline
        )
        var catalog = ArtistCatalog(
            artistName: "Stick", songs: [], assets: [], events: [], masterCompositions: [local]
        )

        let older = MasterComposition(
            id: compositionID,
            songID: songID,
            sections: [],
            outputAssetID: UUID(),
            updatedAt: baseline.addingTimeInterval(-1)
        )
        XCTAssertTrue(CanonicalSync.apply(
            changes: [SyncLogic.change(forMasterComposition: older)], to: &catalog
        ).isEmpty)
        XCTAssertEqual(catalog.masterComposition(for: songID)?.outputAssetID, oldAsset)

        let newer = MasterComposition(
            id: compositionID,
            songID: songID,
            sections: [],
            outputAssetID: newerAsset,
            updatedAt: baseline.addingTimeInterval(1)
        )
        XCTAssertEqual(CanonicalSync.apply(
            changes: [SyncLogic.change(forMasterComposition: newer)], to: &catalog
        ).count, 1)
        XCTAssertEqual(catalog.masterComposition(for: songID)?.outputAssetID, newerAsset)
    }

    func testSongTombstoneRemovesOwnedCanonicalHistory() {
        let songID = UUID()
        let song = Song(
            id: songID, title: "Delete Me", era: "2026", status: .review,
            progress: 0, qualityScore: 0, risk: "low", sections: []
        )
        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: Date(), target: .song,
            action: .approved, selectedAssetID: nil
        )
        let composition = MasterComposition(songID: songID, sections: [])
        var catalog = ArtistCatalog(
            artistName: "Stick", songs: [song], assets: [], events: [],
            decisions: [decision], masterCompositions: [composition]
        )

        _ = CanonicalSync.apply(changes: [
            SyncLogic.tombstone(kind: .song, id: songID.uuidString)
        ], to: &catalog)

        XCTAssertTrue(catalog.songs.isEmpty)
        XCTAssertTrue(catalog.decisions.isEmpty)
        XCTAssertTrue(catalog.masterCompositions.isEmpty)
    }
}
