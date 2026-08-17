import XCTest
import ArtistOSCore
@testable import ArtistOS

final class CanonicalSyncPersistenceTests: XCTestCase {
    private func assertDateEqual(
        _ actual: Date,
        _ expected: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.001,
            file: file,
            line: line
        )
    }

    private func assertDecisionEqual(
        _ actual: CreativeDecision?,
        _ expected: CreativeDecision?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            if expected != nil {
                XCTFail("Expected decision to round-trip from persistence", file: file, line: line)
            }
            return
        }
        guard let expected else {
            return XCTFail("Expected decision to round-trip from persistence", file: file, line: line)
        }
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.songID, expected.songID, file: file, line: line)
        assertDateEqual(actual.timestamp, expected.timestamp, file: file, line: line)
        XCTAssertEqual(actual.target, expected.target, file: file, line: line)
        XCTAssertEqual(actual.action, expected.action, file: file, line: line)
        XCTAssertEqual(actual.selectedAssetID, expected.selectedAssetID, file: file, line: line)
        XCTAssertEqual(actual.rejectedAssetIDs, expected.rejectedAssetIDs, file: file, line: line)
        XCTAssertEqual(actual.relatedEventIDs, expected.relatedEventIDs, file: file, line: line)
        XCTAssertEqual(actual.reason, expected.reason, file: file, line: line)
        XCTAssertEqual(actual.source, expected.source, file: file, line: line)
    }

    private func assertMasterCompositionEqual(
        _ actual: MasterComposition?,
        _ expected: MasterComposition?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            if expected != nil {
                XCTFail("Expected composition to round-trip from persistence", file: file, line: line)
            }
            return
        }
        guard let expected else {
            return XCTFail("Expected composition to round-trip from persistence", file: file, line: line)
        }
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.songID, expected.songID, file: file, line: line)
        XCTAssertEqual(actual.outputAssetID, expected.outputAssetID, file: file, line: line)
        assertDateEqual(actual.updatedAt, expected.updatedAt, file: file, line: line)
        XCTAssertEqual(actual.sections.count, expected.sections.count, file: file, line: line)

        for (actualSection, expectedSection) in zip(actual.sections, expected.sections) {
            XCTAssertEqual(actualSection.id, expectedSection.id, file: file, line: line)
            XCTAssertEqual(actualSection.name, expectedSection.name, file: file, line: line)
            XCTAssertEqual(actualSection.role, expectedSection.role, file: file, line: line)
            XCTAssertEqual(actualSection.state, expectedSection.state, file: file, line: line)
            XCTAssertEqual(actualSection.confidence, expectedSection.confidence, file: file, line: line)
            XCTAssertEqual(actualSection.note, expectedSection.note, file: file, line: line)
            XCTAssertEqual(actualSection.selections.count, expectedSection.selections.count, file: file, line: line)

            for (actualSelection, expectedSelection) in zip(actualSection.selections, expectedSection.selections) {
                XCTAssertEqual(actualSelection.id, expectedSelection.id, file: file, line: line)
                XCTAssertEqual(actualSelection.kind, expectedSelection.kind, file: file, line: line)
                XCTAssertEqual(actualSelection.referenceID, expectedSelection.referenceID, file: file, line: line)
                XCTAssertEqual(actualSelection.decisionID, expectedSelection.decisionID, file: file, line: line)
                assertDateEqual(actualSelection.selectedAt, expectedSelection.selectedAt, file: file, line: line)
            }
        }
    }

    func testAcceptedCanonicalChangesRoundTripThroughGRDB() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let songID = UUID()
        let assetA = UUID()
        let assetB = UUID()
        let eventID = UUID()
        let decisionID = UUID()
        let compositionID = UUID()
        let sectionID = UUID()
        let now = Date()

        let song = Song(
            id: songID, title: "Golden State", era: "2026", status: .review,
            progress: 0.8, qualityScore: 0.9, risk: "low", sections: [], updatedAt: now
        )
        var catalog = ArtistCatalog(artistName: "STICK", songs: [song], assets: [], events: [])
        store.seed(catalog)

        let event = CreativeEvent(
            id: eventID, songID: songID, timestamp: now.addingTimeInterval(1),
            target: .hook, operation: .recordingUpdated,
            beforeAssetID: assetA, afterAssetID: assetB,
            summary: "Hook recording changed.", confidence: 1
        )
        let decision = CreativeDecision(
            id: decisionID, songID: songID, timestamp: now.addingTimeInterval(2),
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
                    selectedAt: now.addingTimeInterval(2)
                )],
                state: .locked,
                confidence: 1
            )],
            outputAssetID: assetB,
            updatedAt: now.addingTimeInterval(3)
        )

        let applied = try CanonicalSyncPersistence.apply(
            changes: [
                SyncLogic.change(forEvent: event),
                SyncLogic.change(forDecision: decision),
                SyncLogic.change(forMasterComposition: composition)
            ],
            to: &catalog,
            store: store
        )

        XCTAssertEqual(applied.map(\.kind), [.event, .decision, .masterComposition])
        let loaded = store.loadCatalog(artistName: "STICK")
        XCTAssertEqual(loaded.events.first?.beforeAssetID, assetA)
        XCTAssertEqual(loaded.events.first?.afterAssetID, assetB)

        // CanonicalSync normalizes Date values through the millisecond wire
        // contract before persistence. Compare disk with the accepted in-memory
        // canonical state, not the higher-precision pre-wire source objects.
        assertDecisionEqual(loaded.decisions.first, catalog.decisions.first)
        assertMasterCompositionEqual(
            loaded.masterComposition(for: songID),
            catalog.masterComposition(for: songID)
        )
    }

    func testCanonicalTombstonesDeletePersistedRows() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let songID = UUID()
        let event = CreativeEvent(
            id: UUID(), songID: songID, timestamp: Date(), target: .song,
            operation: .imported, beforeAssetID: nil, afterAssetID: nil,
            summary: "Imported.", confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: Date().addingTimeInterval(1),
            target: .song, action: .approved, selectedAssetID: nil
        )
        let composition = MasterComposition(
            id: UUID(), songID: songID, sections: [], updatedAt: Date().addingTimeInterval(2)
        )
        let song = Song(
            id: songID, title: "Delete pieces", era: "2026", status: .review,
            progress: 0, qualityScore: 0, risk: "low", sections: []
        )
        var catalog = ArtistCatalog(
            artistName: "STICK", songs: [song], assets: [], events: [event],
            decisions: [decision], masterCompositions: [composition]
        )
        store.seed(catalog)

        _ = try CanonicalSyncPersistence.apply(
            changes: [
                SyncLogic.tombstone(kindRaw: SyncLogic.decisionKind, id: decision.id.uuidString),
                SyncLogic.tombstone(kindRaw: SyncLogic.masterCompositionKind, id: composition.id.uuidString),
                SyncLogic.tombstone(kind: .event, id: event.id.uuidString)
            ],
            to: &catalog,
            store: store
        )

        let loaded = store.loadCatalog(artistName: "STICK")
        XCTAssertTrue(loaded.events.isEmpty)
        XCTAssertTrue(loaded.decisions.isEmpty)
        XCTAssertTrue(loaded.masterCompositions.isEmpty)
    }

    func testRejectedStaleCanonicalChangeIsNotPersisted() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let songID = UUID()
        let baseline = Date()
        let local = MasterComposition(
            id: UUID(), songID: songID, sections: [], outputAssetID: UUID(), updatedAt: baseline
        )
        let song = Song(
            id: songID, title: "Stable", era: "2026", status: .review,
            progress: 0, qualityScore: 0, risk: "low", sections: []
        )
        var catalog = ArtistCatalog(
            artistName: "STICK", songs: [song], assets: [], events: [], masterCompositions: [local]
        )
        store.seed(catalog)

        let stale = MasterComposition(
            id: local.id, songID: songID, sections: [], outputAssetID: UUID(),
            updatedAt: baseline.addingTimeInterval(-60)
        )
        let applied = try CanonicalSyncPersistence.apply(
            changes: [SyncLogic.change(forMasterComposition: stale)],
            to: &catalog,
            store: store
        )

        XCTAssertTrue(applied.isEmpty)
        let loaded = store.loadCatalog(artistName: "STICK").masterComposition(for: songID)
        assertMasterCompositionEqual(loaded, local)
    }
}
