import XCTest
import ArtistOSCore
@testable import ArtistOS

final class CanonicalSyncPersistenceTests: XCTestCase {
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

        let memoryDecision = try XCTUnwrap(catalog.decisions.first)
        let diskDecision = try XCTUnwrap(loaded.decisions.first)
        XCTAssertEqual(diskDecision.id, memoryDecision.id)
        XCTAssertEqual(diskDecision.songID, memoryDecision.songID)
        XCTAssertEqual(diskDecision.target, memoryDecision.target)
        XCTAssertEqual(diskDecision.action, memoryDecision.action)
        XCTAssertEqual(diskDecision.selectedAssetID, memoryDecision.selectedAssetID)
        XCTAssertEqual(diskDecision.rejectedAssetIDs, memoryDecision.rejectedAssetIDs)
        XCTAssertEqual(diskDecision.relatedEventIDs, memoryDecision.relatedEventIDs)
        XCTAssertEqual(diskDecision.reason, memoryDecision.reason)
        XCTAssertEqual(diskDecision.source, memoryDecision.source)
        XCTAssertEqual(
            diskDecision.timestamp.timeIntervalSince1970,
            memoryDecision.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )

        let memoryComposition = try XCTUnwrap(catalog.masterComposition(for: songID))
        let diskComposition = try XCTUnwrap(loaded.masterComposition(for: songID))
        XCTAssertEqual(diskComposition.id, memoryComposition.id)
        XCTAssertEqual(diskComposition.songID, memoryComposition.songID)
        XCTAssertEqual(diskComposition.outputAssetID, memoryComposition.outputAssetID)
        XCTAssertEqual(diskComposition.sections.count, memoryComposition.sections.count)
        XCTAssertEqual(diskComposition.sections.first?.id, memoryComposition.sections.first?.id)
        XCTAssertEqual(diskComposition.sections.first?.name, memoryComposition.sections.first?.name)
        XCTAssertEqual(diskComposition.sections.first?.role, memoryComposition.sections.first?.role)
        XCTAssertEqual(diskComposition.sections.first?.state, memoryComposition.sections.first?.state)
        XCTAssertEqual(diskComposition.sections.first?.confidence, memoryComposition.sections.first?.confidence)
        XCTAssertEqual(diskComposition.sections.first?.note, memoryComposition.sections.first?.note)
        XCTAssertEqual(
            diskComposition.updatedAt.timeIntervalSince1970,
            memoryComposition.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        let memorySelection = try XCTUnwrap(memoryComposition.sections.first?.selection(.sourceAsset))
        let diskSelection = try XCTUnwrap(diskComposition.sections.first?.selection(.sourceAsset))
        XCTAssertEqual(diskSelection.id, memorySelection.id)
        XCTAssertEqual(diskSelection.kind, memorySelection.kind)
        XCTAssertEqual(diskSelection.referenceID, memorySelection.referenceID)
        XCTAssertEqual(diskSelection.decisionID, memorySelection.decisionID)
        XCTAssertEqual(
            diskSelection.selectedAt.timeIntervalSince1970,
            memorySelection.selectedAt.timeIntervalSince1970,
            accuracy: 0.001
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
        XCTAssertEqual(loaded?.id, local.id)
        XCTAssertEqual(loaded?.songID, local.songID)
        XCTAssertEqual(loaded?.outputAssetID, local.outputAssetID)
        XCTAssertEqual(loaded?.sections, local.sections)
        XCTAssertEqual(
            loaded?.updatedAt.timeIntervalSince1970 ?? 0,
            local.updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
