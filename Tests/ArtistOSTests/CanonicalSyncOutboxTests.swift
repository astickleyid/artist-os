import XCTest
import ArtistOSCore
import GRDB
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

        try store.removeCanonicalSyncOutbox(keys: pending.map(\.key))
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty)
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

    func testOutboxReadFailsClosedOnCorruptStoredPayload() throws {
        let database = try AppDatabase.inMemory()
        let store = CatalogStore(database: database)
        try database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO canonicalSyncOutbox (key, kind, entityID, updatedAt, payload) VALUES (?, ?, ?, ?, ?)",
                arguments: ["decision:broken", SyncLogic.decisionKind, "broken", 1.0, Data("[]".utf8)]
            )
        }

        XCTAssertThrowsError(try store.canonicalSyncOutbox()) { error in
            guard case CanonicalSyncOutboxError.invalidStoredPayload = error else {
                return XCTFail("Expected invalidStoredPayload, got \(error)")
            }
        }
    }
}
