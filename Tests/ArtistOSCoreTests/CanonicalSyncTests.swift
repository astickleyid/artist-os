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

        let syncedDecision = try XCTUnwrap(catalog.decisions.first)
        XCTAssertEqual(syncedDecision.id, decision.id)
        XCTAssertEqual(syncedDecision.songID, decision.songID)
        XCTAssertEqual(syncedDecision.target, decision.target)
        XCTAssertEqual(syncedDecision.action, decision.action)
        XCTAssertEqual(syncedDecision.selectedAssetID, decision.selectedAssetID)
        XCTAssertEqual(syncedDecision.rejectedAssetIDs, decision.rejectedAssetIDs)
        XCTAssertEqual(syncedDecision.relatedEventIDs, decision.relatedEventIDs)
        XCTAssertEqual(syncedDecision.reason, decision.reason)
        XCTAssertEqual(syncedDecision.source, decision.source)
        XCTAssertEqual(
            syncedDecision.timestamp.timeIntervalSince1970,
            decision.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )

        let syncedComposition = try XCTUnwrap(catalog.masterComposition(for: songID))
        XCTAssertEqual(syncedComposition.id, composition.id)
        XCTAssertEqual(syncedComposition.songID, composition.songID)
        XCTAssertEqual(syncedComposition.outputAssetID, composition.outputAssetID)
        XCTAssertEqual(syncedComposition.sections.count, 1)
        XCTAssertEqual(syncedComposition.sections.first?.id, sectionID)
        XCTAssertEqual(syncedComposition.sections.first?.name, "Hook")
        XCTAssertEqual(syncedComposition.sections.first?.state, .locked)
        XCTAssertEqual(
            syncedComposition.updatedAt.timeIntervalSince1970,
            composition.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            syncedComposition.sections.first?.selection(.sourceAsset)?.decisionID,
            decisionID
        )
        XCTAssertEqual(
            syncedComposition.sections.first?.selection(.sourceAsset)?.referenceID,
            assetB
        )
        XCTAssertEqual(
            syncedComposition.sections.first?.selection(.sourceAsset)?.selectedAt.timeIntervalSince1970 ?? 0,
            composition.sections.first?.selection(.sourceAsset)?.selectedAt.timeIntervalSince1970 ?? 0,
            accuracy: 0.001
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
