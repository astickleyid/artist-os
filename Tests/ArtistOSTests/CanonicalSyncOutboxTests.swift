import XCTest
import ArtistOSCore
@testable import ArtistOS

final class CanonicalSyncOutboxTests: XCTestCase {
    func testOutboxPersistsAllCanonicalKindsAndTombstones() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let now = Date()
        let songID = UUID()
        let assetID = UUID()
        let eventID = UUID()
        let decisionID = UUID()
        let compositionID = UUID()

        let changes: [SyncLogic.JSONDict] = [
            SyncLogic.change(kind: .song, id: songID.uuidString, updatedAt: now, data: ["id": songID.uuidString]),
            SyncLogic.change(kind: .asset, id: assetID.uuidString, updatedAt: now, data: ["id": assetID.uuidString]),
            SyncLogic.change(kind: .event, id: eventID.uuidString, updatedAt: now, data: ["id": eventID.uuidString]),
            SyncLogic.change(kindRaw: SyncLogic.decisionKind, id: decisionID.uuidString, updatedAt: now, data: ["id": decisionID.uuidString]),
            SyncLogic.change(kindRaw: SyncLogic.masterCompositionKind, id: compositionID.uuidString, updatedAt: now, data: ["id": compositionID.uuidString]),
            SyncLogic.tombstone(kindRaw: SyncLogic.masterCompositionKind, id: UUID().uuidString)
        ]

        try store.enqueueCanonicalSyncChanges(changes)
        let pending = try store.canonicalSyncOutbox()

        XCTAssertEqual(pending.count, 6)
        XCTAssertEqual(Set(pending.compactMap { $0.change["kind"] as? String }),
                       Set(["song", "asset", "event", "decision", "masterComposition"]))
        XCTAssertTrue(pending.contains { ($0.change["deleted"] as? Bool) == true })
    }

    func testOutboxCoalescesByKindAndEntityKeepingNewestChange() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let id = UUID().uuidString
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        try store.enqueueCanonicalSyncChanges([
            SyncLogic.change(kindRaw: SyncLogic.masterCompositionKind, id: id, updatedAt: newer,
                             data: ["id": id, "note": "new"])
        ])
        try store.enqueueCanonicalSyncChanges([
            SyncLogic.change(kindRaw: SyncLogic.masterCompositionKind, id: id, updatedAt: older,
                             data: ["id": id, "note": "old"])
        ])

        let pending = try store.canonicalSyncOutbox()
        XCTAssertEqual(pending.count, 1)
        let data = pending[0].change["data"] as? SyncLogic.JSONDict
        XCTAssertEqual(data?["note"] as? String, "new")
    }

    func testOutboxRowsAreRemovedOnlyByExplicitAcknowledgementCleanup() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let id = UUID().uuidString
        try store.enqueueCanonicalSyncChanges([
            SyncLogic.tombstone(kindRaw: SyncLogic.decisionKind, id: id)
        ])

        let pending = try store.canonicalSyncOutbox()
        XCTAssertEqual(pending.count, 1)

        try store.removeCanonicalSyncOutbox(pending)
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }

    func testAcknowledgingOlderPayloadDoesNotDeleteNewerQueuedEditForSameEntity() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let id = UUID().uuidString
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        try store.enqueueCanonicalSyncChanges([
            SyncLogic.change(kindRaw: SyncLogic.masterCompositionKind, id: id, updatedAt: older,
                             data: ["id": id, "note": "older in flight"])
        ])
        let inFlight = try store.canonicalSyncOutbox()

        try store.enqueueCanonicalSyncChanges([
            SyncLogic.change(kindRaw: SyncLogic.masterCompositionKind, id: id, updatedAt: newer,
                             data: ["id": id, "note": "newer queued"])
        ])
        try store.removeCanonicalSyncOutbox(inFlight)

        let remaining = try store.canonicalSyncOutbox()
        XCTAssertEqual(remaining.count, 1)
        let data = remaining[0].change["data"] as? SyncLogic.JSONDict
        XCTAssertEqual(data?["note"] as? String, "newer queued")
    }

    func testOutboxRejectsMalformedChangeInsteadOfSilentlyDroppingIt() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let malformed: SyncLogic.JSONDict = [
            "kind": SyncLogic.decisionKind,
            "id": UUID().uuidString,
            "data": ["reason": "missing timestamp"]
        ]

        XCTAssertThrowsError(try store.enqueueCanonicalSyncChanges([malformed])) { error in
            guard case CanonicalSyncOutboxError.invalidUpdatedAt = error else {
                return XCTFail("Expected invalidUpdatedAt, got \(error)")
            }
        }
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }

    func testOutboxRejectsNonSerializableChangeInsteadOfSilentlyDroppingIt() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let malformed: SyncLogic.JSONDict = [
            "kind": SyncLogic.decisionKind,
            "id": UUID().uuidString,
            "updatedAt": Date().timeIntervalSince1970 * 1000,
            "data": ["invalid": Date()]
        ]

        XCTAssertThrowsError(try store.enqueueCanonicalSyncChanges([malformed])) { error in
            guard case CanonicalSyncOutboxError.invalidJSONObject = error else {
                return XCTFail("Expected invalidJSONObject, got \(error)")
            }
        }
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }

    func testMasterAnnotationCommitsDomainTruthAndOutboxTogether() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Atomic annotation")
        song.sections[0].note = "keep this take"
        song.updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        var composition = MasterComposition.projected(from: song)
        composition.sections[0].note = "keep this take"
        composition.updatedAt = song.updatedAt
        let changes = [
            SyncLogic.change(forSong: song),
            SyncLogic.change(forMasterComposition: composition)
        ]

        try store.commitMasterAnnotation(
            song: song,
            masterComposition: composition,
            syncChanges: changes
        )

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.songs.first?.sections.first?.note, "keep this take")
        XCTAssertEqual(loaded.masterCompositions.first?.sections.first?.note, "keep this take")
        XCTAssertEqual(try store.canonicalSyncOutbox().count, 2)
    }

    func testInvalidOutboxPayloadRollsBackCanonicalMutationTransaction() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Must rollback")
        let composition = MasterComposition.projected(from: song)
        let malformed: SyncLogic.JSONDict = [
            "kind": SyncLogic.masterCompositionKind,
            "id": composition.id.uuidString,
            "data": ["reason": "missing timestamp"]
        ]

        XCTAssertThrowsError(try store.commitMasterAnnotation(
            song: song,
            masterComposition: composition,
            syncChanges: [malformed]
        ))

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertTrue(loaded.songs.isEmpty)
        XCTAssertTrue(loaded.masterCompositions.isEmpty)
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }

    func testApprovalCommitsCanonicalTruthAndOutboxTogether() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Atomic approval")
        let timestamp = Date(timeIntervalSince1970: 2_000_000_100)
        song.updatedAt = timestamp
        let event = CreativeEvent(
            id: UUID(),
            songID: song.id,
            timestamp: timestamp,
            target: .master,
            operation: .approved,
            beforeAssetID: nil,
            afterAssetID: nil,
            summary: "Master approved.",
            confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(),
            songID: song.id,
            timestamp: timestamp,
            target: .master,
            action: .approved,
            selectedAssetID: nil,
            relatedEventIDs: [event.id],
            reason: "Approved for the next mix pass.",
            source: .artist
        )
        var composition = MasterComposition.projected(from: song)
        composition.updatedAt = timestamp
        let changes = [
            SyncLogic.change(forSong: song),
            SyncLogic.change(forEvent: event),
            SyncLogic.change(forDecision: decision),
            SyncLogic.change(forMasterComposition: composition)
        ]

        try store.commitApproval(
            song: song,
            events: [event],
            decision: decision,
            masterComposition: composition,
            syncChanges: changes
        )

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.songs.map(\.id), [song.id])
        XCTAssertEqual(loaded.events.map(\.id), [event.id])
        XCTAssertEqual(loaded.decisions.map(\.id), [decision.id])
        XCTAssertEqual(loaded.masterCompositions.map(\.id), [composition.id])
        XCTAssertEqual(try store.canonicalSyncOutbox().count, 4)
    }

    func testInvalidOutboxPayloadRollsBackApprovalTransaction() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Approval must rollback")
        let timestamp = Date(timeIntervalSince1970: 2_000_000_200)
        let event = CreativeEvent(
            id: UUID(),
            songID: song.id,
            timestamp: timestamp,
            target: .master,
            operation: .approved,
            beforeAssetID: nil,
            afterAssetID: nil,
            summary: "Must not persist.",
            confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(),
            songID: song.id,
            timestamp: timestamp,
            target: .master,
            action: .approved,
            selectedAssetID: nil,
            relatedEventIDs: [event.id],
            reason: "Must roll back.",
            source: .artist
        )
        let composition = MasterComposition.projected(from: song)
        let malformed: SyncLogic.JSONDict = [
            "kind": SyncLogic.decisionKind,
            "id": decision.id.uuidString,
            "data": ["reason": "missing timestamp"]
        ]

        XCTAssertThrowsError(try store.commitApproval(
            song: song,
            events: [event],
            decision: decision,
            masterComposition: composition,
            syncChanges: [malformed]
        ))

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertTrue(loaded.songs.isEmpty)
        XCTAssertTrue(loaded.events.isEmpty)
        XCTAssertTrue(loaded.decisions.isEmpty)
        XCTAssertTrue(loaded.masterCompositions.isEmpty)
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
    }
}
