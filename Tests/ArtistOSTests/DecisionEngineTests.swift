import XCTest
@testable import ArtistOS

final class DecisionEngineTests: XCTestCase {
    private func asset(_ role: AssetRole, _ v: String?, _ o: Int?, songID: UUID) -> Asset {
        Asset(id: UUID(), title: "t", originalFilename: "f", role: role,
              createdAt: Date(), duration: nil, localURLBookmark: nil,
              songID: songID, version: v, vOrder: o)
    }

    func testD1EscalatesOnceAndNeverTouchesLocked() {
        var song = ImportService.makeSong(title: "T") // Intro/Verse 1/Hook/Bridge/Outro
        let hooks = [asset(.hook, "v1", 1, songID: song.id), asset(.hook, "v2", 2, songID: song.id)]

        var fired = VersionIntelligence.applyAutoDecisions(song: &song, assets: hooks)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(song.sections[2].state, .needsDecision)

        fired = VersionIntelligence.applyAutoDecisions(song: &song, assets: hooks)
        XCTAssertTrue(fired.isEmpty) // idempotent

        song.sections[2].state = .locked
        XCTAssertTrue(VersionIntelligence.applyAutoDecisions(song: &song, assets: hooks).isEmpty)
    }

    func testD1RequiresTwoCandidates() {
        var song = ImportService.makeSong(title: "T")
        let one = [asset(.hook, "v1", 1, songID: song.id)]
        XCTAssertTrue(VersionIntelligence.applyAutoDecisions(song: &song, assets: one).isEmpty)
        XCTAssertEqual(song.sections[2].state, .open)
    }

    func testD2MasterLifecycle() {
        var song = ImportService.makeSong(title: "T")
        let v1 = asset(.fullMix, "v1", 1, songID: song.id)
        let v2 = asset(.fullMix, "v2", 2, songID: song.id)

        var decisions = VersionIntelligence.decisions(for: song, assets: [v1, v2])
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.kind, .master)

        song.masterAssetID = v2.id // pin latest -> resolved
        XCTAssertTrue(VersionIntelligence.decisions(for: song, assets: [v1, v2]).isEmpty)

        song.masterAssetID = v1.id // pinned older -> challenged
        decisions = VersionIntelligence.decisions(for: song, assets: [v1, v2])
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions.first?.detail.contains("challenges") ?? false)
    }

    @MainActor
    func testEnginePersistsFlagsAndPinning() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Engine Song")
        let songID = state.catalog.songs[0].id
        state.catalog.assets.append(asset(.hook, "take1", 1, songID: songID))
        state.catalog.assets.append(asset(.hook, "take2", 2, songID: songID))

        state.runDecisionEngine(songIDs: [songID])
        XCTAssertEqual(state.catalog.songs[0].sections[2].state, .needsDecision)
        XCTAssertTrue(state.catalog.events.contains {
            $0.operation == .needsDecision && $0.summary.contains("auto-flagged")
        })
        XCTAssertEqual(state.pendingDecisions.count, 1)

        let mixA = asset(.fullMix, "v1", 1, songID: songID)
        let mixB = asset(.fullMix, "v2", 2, songID: songID)
        state.catalog.assets.append(contentsOf: [mixA, mixB])
        XCTAssertEqual(state.pendingDecisions.count, 2)

        state.pinMaster(songID: songID, assetID: mixB.id)
        XCTAssertEqual(state.catalog.songs[0].masterAssetID, mixB.id)
        XCTAssertTrue(state.catalog.events.contains { $0.summary.contains("pinned as current master") })
        XCTAssertEqual(state.pendingDecisions.count, 1) // slot decision remains

        // Persistence round-trip
        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs[0].masterAssetID, mixB.id)
        XCTAssertEqual(reloaded.songs[0].sections[2].state, .needsDecision)
    }
}
