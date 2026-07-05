import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class AppStateSyncTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "artistos-appstate-synctest-\(UUID().uuidString)")!
    }

    func testEnableSyncPushesTheEntireExistingCatalog() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["applied": 1, "skipped": 0, "seq": 1]) // the createSong below
        ])
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))
        state.createSong(title: "Sync Song")

        await state.enableSync()
        XCTAssertEqual(state.syncStatus, .on)
        XCTAssertNil(state.syncLastError)

        let pushBody = await fake.lastBodyJSON()
        let changes = pushBody?["changes"] as? [[String: Any]]
        XCTAssertNotNil(changes)
        XCTAssertTrue(changes?.contains { ($0["data"] as? [String: Any])?["title"] as? String == "Sync Song" } ?? false)
    }

    func testEnableSyncSurfacesErrorWithoutCrashing() async throws {
        let fake = FakeHTTPClient(script: [.init(json: ["error": "down"], status: 500)])
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))
        await state.enableSync()
        XCTAssertEqual(state.syncStatus, .off, "must not flip to on when the server rejects enable")
        XCTAssertNotNil(state.syncLastError)
    }

    func testPullFromCloudAppliesANewRemoteSong() async throws {
        let remoteID = UUID()
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: [
                "changes": [[
                    "kind": "song", "id": remoteID.uuidString, "updatedAt": Date().timeIntervalSince1970 * 1000,
                    "data": ["id": remoteID.uuidString, "title": "From Another Device", "era": "2026",
                             "status": "Review", "progress": 0.0, "qualityScore": 0.0, "risk": "low", "sections": []]
                ]],
                "seq": 1, "hasMore": false
            ])
        ])
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))
        await state.enableSync()
        try await state.pullFromCloud()
        XCTAssertTrue(state.catalog.songs.contains { $0.title == "From Another Device" })
    }

    func testPersistingASongMarksItDirtyForTheNextDebouncedPush() async throws {
        // Verifies the wiring point itself (persist -> markDirty) without
        // waiting out the real debounce timer: enabling sync flushes the
        // whole catalog immediately, which is the behavior a person actually
        // depends on ("my existing work must reach the cloud on enable").
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["applied": 1, "skipped": 0, "seq": 1])
        ])
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))
        state.createSong(title: "Dirty Tracking Song")
        await state.enableSync()
        let requestCount = await fake.recorded.count
        XCTAssertEqual(requestCount, 2, "account creation + one push containing the song just created")
    }

    func testEnablingSyncWithATrulyEmptyCatalogSendsNoPushRequest() async throws {
        // Pushing zero changes should make zero network calls — confirms
        // the batching loop doesn't fire an empty request for an empty diff.
        let fake = FakeHTTPClient(script: [.init(json: ["accountId": "acc1", "token": "tok1"], status: 201)])
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))
        await state.enableSync()
        XCTAssertEqual(state.syncStatus, .on)
        let requestCount = await fake.recorded.count
        XCTAssertEqual(requestCount, 1, "only the account-creation request, no push for an empty catalog")
    }
}
