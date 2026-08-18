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

    func testEnableSyncPushesPersistedDecisionAndMasterComposition() async throws {
        let songID = UUID()
        let song = Song(
            id: songID, title: "Existing Canonical Song", era: "2026", status: .review,
            progress: 0, qualityScore: 0, risk: "low", sections: []
        )
        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: Date(), target: .song,
            action: .approved, selectedAssetID: nil, reason: "Keep the structure", source: .artist
        )
        let composition = MasterComposition(
            id: UUID(), songID: songID, sections: [], updatedAt: Date().addingTimeInterval(1)
        )
        let store = CatalogStore(database: try AppDatabase.inMemory())
        store.seed(ArtistCatalog(
            artistName: "STICK", songs: [song], assets: [], events: [],
            decisions: [decision], masterCompositions: [composition]
        ))
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["applied": 3, "skipped": 0, "seq": 3])
        ])
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))

        await state.enableSync()

        let pushBody = await fake.lastBodyJSON()
        let changes = pushBody?["changes"] as? [[String: Any]] ?? []
        XCTAssertTrue(changes.contains {
            ($0["kind"] as? String) == SyncLogic.decisionKind && ($0["id"] as? String) == decision.id.uuidString
        })
        XCTAssertTrue(changes.contains {
            ($0["kind"] as? String) == SyncLogic.masterCompositionKind && ($0["id"] as? String) == composition.id.uuidString
        })
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

    func testPullFromCloudPersistsCanonicalDecisionAndMasterComposition() async throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let songID = UUID()
        let song = Song(
            id: songID, title: "Canonical Pull", era: "2026", status: .review,
            progress: 0, qualityScore: 0, risk: "low", sections: [], updatedAt: Date()
        )
        store.seed(ArtistCatalog(artistName: "STICK", songs: [song], assets: [], events: []))

        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: Date().addingTimeInterval(10),
            target: .song, action: .approved, selectedAssetID: nil,
            reason: "Keep this structure", source: .artist
        )
        let composition = MasterComposition(
            id: UUID(), songID: songID, sections: [],
            updatedAt: Date().addingTimeInterval(11)
        )

        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["applied": 1, "skipped": 0, "seq": 1]),
            .init(json: [
                "changes": [
                    SyncLogic.change(forDecision: decision),
                    SyncLogic.change(forMasterComposition: composition)
                ],
                "seq": 2, "hasMore": false
            ])
        ])
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false,
                             sync: SyncService(client: fake, defaults: freshDefaults()))

        await state.enableSync()
        try await state.pullFromCloud()

        XCTAssertEqual(state.catalog.decisions.first?.id, decision.id)
        XCTAssertEqual(state.catalog.masterComposition(for: songID)?.id, composition.id)

        let reloaded = store.loadCatalog(artistName: "STICK")
        XCTAssertEqual(reloaded.decisions.first?.id, decision.id)
        XCTAssertEqual(reloaded.masterComposition(for: songID)?.id, composition.id)
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
