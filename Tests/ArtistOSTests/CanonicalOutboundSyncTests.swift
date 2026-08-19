import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalOutboundSyncTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "artistos-canonical-outbound-\(UUID().uuidString)")!
    }

    func testCanonicalPushRetriesTransientFailureAndClearsErrorAfterSuccess() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["error": "temporary"], status: 500),
            .init(json: ["applied": 1, "skipped": 0, "seq": 1])
        ])
        let state = AppState(
            store: CatalogStore(database: try AppDatabase.inMemory()),
            seedIfNeeded: false,
            enableWatching: false,
            sync: SyncService(client: fake, defaults: freshDefaults())
        )
        await state.enableSync()

        let decision = CreativeDecision(
            id: UUID(), songID: UUID(), timestamp: Date(), target: .song,
            action: .approved, selectedAssetID: nil, reason: "Retry me", source: .artist
        )
        let success = await state.pushCanonicalChangesWithRetry(
            [SyncLogic.change(forDecision: decision)],
            retryDelaysNanoseconds: [0, 0]
        )

        XCTAssertTrue(success)
        XCTAssertNil(state.syncLastError)
        let requestCount = await fake.recorded.count
        XCTAssertEqual(requestCount, 3, "enable + failed push + successful retry")
        let body = await fake.lastBodyJSON()
        let changes = body?["changes"] as? [[String: Any]] ?? []
        XCTAssertEqual(changes.first?["kind"] as? String, SyncLogic.decisionKind)
        XCTAssertEqual(changes.first?["id"] as? String, decision.id.uuidString)
    }

    func testCanonicalPushLeavesErrorVisibleAfterRetryBudgetIsExhausted() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["error": "still down"], status: 503),
            .init(json: ["error": "still down"], status: 503)
        ])
        let state = AppState(
            store: CatalogStore(database: try AppDatabase.inMemory()),
            seedIfNeeded: false,
            enableWatching: false,
            sync: SyncService(client: fake, defaults: freshDefaults())
        )
        await state.enableSync()

        let composition = MasterComposition(id: UUID(), songID: UUID(), sections: [], updatedAt: Date())
        let success = await state.pushCanonicalChangesWithRetry(
            [SyncLogic.change(forMasterComposition: composition)],
            retryDelaysNanoseconds: [0, 0]
        )

        XCTAssertFalse(success)
        XCTAssertNotNil(state.syncLastError)
        let requestCount = await fake.recorded.count
        XCTAssertEqual(requestCount, 3, "enable + two failed attempts")
    }

    func testCanonicalPushDoesNothingWhileSyncIsOff() async throws {
        let fake = FakeHTTPClient(script: [])
        let state = AppState(
            store: CatalogStore(database: try AppDatabase.inMemory()),
            seedIfNeeded: false,
            enableWatching: false,
            sync: SyncService(client: fake, defaults: freshDefaults())
        )
        let decision = CreativeDecision(
            id: UUID(), songID: UUID(), timestamp: Date(), target: .song,
            action: .selected, selectedAssetID: nil, source: .artist
        )

        let success = await state.pushCanonicalChangesWithRetry(
            [SyncLogic.change(forDecision: decision)],
            retryDelaysNanoseconds: [0]
        )

        XCTAssertFalse(success)
        let requestCount = await fake.recorded.count
        XCTAssertEqual(requestCount, 0)
    }
}
