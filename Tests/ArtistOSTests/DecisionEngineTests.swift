import XCTest
import ArtistOSCore
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

    func testCanonicalD1IgnoresStaleLegacyState() {
        var song = ImportService.makeSong(title: "T")
        var composition = MasterComposition.projected(from: song)
        let hooks = [asset(.hook, "v1", 1, songID: song.id), asset(.hook, "v2", 2, songID: song.id)]

        // Legacy mirror claims the hook is locked, but canonical truth remains open.
        song.sections[2].state = .locked
        var fired = VersionIntelligence.applyAutoDecisions(
            masterComposition: &composition,
            assets: hooks
        )
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(composition.sections[2].state, .needsDecision)
        XCTAssertEqual(song.sections[2].state, .locked)

        // Reverse the divergence: stale legacy openness cannot re-escalate a
        // canonically locked slot.
        composition.sections[2].state = .locked
        song.sections[2].state = .open
        fired = VersionIntelligence.applyAutoDecisions(
            masterComposition: &composition,
            assets: hooks
        )
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(composition.sections[2].state, .locked)
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

    func testCanonicalDecisionProjectionOverridesLegacyMirrors() {
        var song = ImportService.makeSong(title: "T")
        let v1 = asset(.fullMix, "v1", 1, songID: song.id)
        let v2 = asset(.fullMix, "v2", 2, songID: song.id)

        // Legacy mirrors say everything is resolved.
        song.sections[2].state = .locked
        song.masterAssetID = v2.id
        XCTAssertTrue(VersionIntelligence.decisions(for: song, assets: [v1, v2]).isEmpty)

        // Canonical truth says the hook and master both require a decision.
        var composition = MasterComposition.projected(from: song)
        composition.sections[2].state = .needsDecision
        composition.outputAssetID = v1.id
        var canonical = VersionIntelligence.decisions(
            for: song,
            masterComposition: composition,
            assets: [v1, v2]
        )
        XCTAssertEqual(canonical.count, 2)
        XCTAssertEqual(canonical.filter { $0.kind == .slot }.count, 1)
        XCTAssertEqual(canonical.filter { $0.kind == .master }.count, 1)

        // Reverse the divergence: stale legacy mirrors must not create phantom decisions.
        song.sections[2].state = .needsDecision
        song.masterAssetID = v1.id
        composition.sections[2].state = .locked
        composition.outputAssetID = v2.id
        canonical = VersionIntelligence.decisions(
            for: song,
            masterComposition: composition,
            assets: [v1, v2]
        )
        XCTAssertTrue(canonical.isEmpty)
        XCTAssertEqual(VersionIntelligence.decisions(for: song, assets: [v1, v2]).count, 2)
    }

    @MainActor
    func testEnginePersistsCanonicalFlagsWithoutInventingArtistDecision() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Engine Song")
        let songID = state.catalog.songs[0].id

        // Materialize canonical truth while deliberately making the legacy
        // mirror disagree. The automatic engine must follow canonical state.
        let canonicalBefore = try XCTUnwrap(state.catalog.masterComposition(for: songID))
        state.catalog.setMasterComposition(canonicalBefore)
        try store.upsert(masterComposition: canonicalBefore)
        state.catalog.songs[0].sections[2].state = .locked
        try store.upsert(song: state.catalog.songs[0])

        state.catalog.assets.append(asset(.hook, "take1", 1, songID: songID))
        state.catalog.assets.append(asset(.hook, "take2", 2, songID: songID))

        let eventCountBefore = state.catalog.events.count
        let decisionCountBefore = state.catalog.decisions.count
        state.runDecisionEngine(songIDs: [songID])

        let canonicalAfter = try XCTUnwrap(state.catalog.masterComposition(for: songID))
        XCTAssertEqual(canonicalAfter.sections[2].state, .needsDecision)
        XCTAssertGreaterThanOrEqual(canonicalAfter.sections[2].confidence, 0.5)
        XCTAssertEqual(state.catalog.songs[0].sections[2].state, .needsDecision)
        XCTAssertEqual(state.catalog.events.count, eventCountBefore + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionCountBefore)
        XCTAssertTrue(state.catalog.events.contains {
            $0.operation == .needsDecision && $0.summary.contains("auto-flagged")
        })
        XCTAssertEqual(state.pendingDecisions.count, 1)

        // D1 remains idempotent after canonical persistence.
        state.runDecisionEngine(songIDs: [songID])
        XCTAssertEqual(state.catalog.events.count, eventCountBefore + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionCountBefore)

        // Persistence round-trip keeps canonical truth and the legacy mirror aligned.
        var reloaded = store.loadCatalog(artistName: "T")
        let reloadedComposition = try XCTUnwrap(reloaded.masterComposition(for: songID))
        XCTAssertEqual(reloadedComposition.sections[2].state, .needsDecision)
        XCTAssertEqual(reloaded.songs[0].sections[2].state, .needsDecision)

        let mixA = asset(.fullMix, "v1", 1, songID: songID)
        let mixB = asset(.fullMix, "v2", 2, songID: songID)
        state.catalog.assets.append(contentsOf: [mixA, mixB])
        XCTAssertEqual(state.pendingDecisions.count, 2)

        state.approveMasterDecision(songID: songID, assetID: mixB.id)
        XCTAssertEqual(state.catalog.masterComposition(for: songID)?.outputAssetID, mixB.id)
        XCTAssertEqual(state.catalog.songs[0].masterAssetID, mixB.id)
        XCTAssertEqual(state.pendingDecisions.count, 1) // slot decision remains

        reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.masterComposition(for: songID)?.outputAssetID, mixB.id)
        XCTAssertEqual(reloaded.songs[0].masterAssetID, mixB.id)
    }
}
