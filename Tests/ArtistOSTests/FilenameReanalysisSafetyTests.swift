import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class FilenameReanalysisSafetyTests: XCTestCase {
    private func makeAsset(
        filename: String,
        role: AssetRole,
        songID: UUID
    ) -> Asset {
        Asset(
            id: UUID(),
            title: filename,
            originalFilename: filename,
            role: role,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: songID
        )
    }

    func testPreflightBlocksCanonicalSourceFromBeingRegroupedWhenLegacyMirrorIsEmpty() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Home")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)

        let asset = makeAsset(filename: "target song v2.wav", role: .hook, songID: songID)
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        var composition = try XCTUnwrap(state.catalog.masterComposition(for: songID))
        let hookIndex = try XCTUnwrap(composition.sections.firstIndex {
            VersionIntelligence.slotTarget(forSectionName: $0.name) == .hook
        })
        composition.sections[hookIndex].setSelection(
            MasterSelection(kind: .sourceAsset, referenceID: asset.id)
        )
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        XCTAssertTrue(state.catalog.songs[0].sections.allSatisfy { $0.assetID == nil })
        XCTAssertFalse(state.canRunFilenameReanalysisSafely())

        state.reanalyzeCatalogSafely()

        XCTAssertEqual(state.catalog.assets.first(where: { $0.id == asset.id })?.songID, songID)
        XCTAssertNotNil(state.catalog.songs.first(where: { $0.id == songID }))
    }

    func testPreflightBlocksCanonicalOutputMasterFromBeingRegrouped() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Home")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)

        let asset = makeAsset(filename: "different song master 2.wav", role: .fullMix, songID: songID)
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        var composition = try XCTUnwrap(state.catalog.masterComposition(for: songID))
        composition.outputAssetID = asset.id
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        XCTAssertNil(state.catalog.songs[0].masterAssetID)
        XCTAssertFalse(state.canRunFilenameReanalysisSafely())

        state.reanalyzeCatalogSafely()

        XCTAssertEqual(state.catalog.assets.first(where: { $0.id == asset.id })?.songID, songID)
    }

    func testPreflightBlocksAssetReferencedByDifferentCanonicalSong() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Home")
        state.createSong(title: "Other")

        let homeID = try XCTUnwrap(state.catalog.songs.first(where: { $0.title == "Home" })?.id)
        let otherID = try XCTUnwrap(state.catalog.songs.first(where: { $0.title == "Other" })?.id)
        let asset = makeAsset(filename: "target song v2.wav", role: .hook, songID: homeID)
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        var otherComposition = try XCTUnwrap(state.catalog.masterComposition(for: otherID))
        let sectionIndex = try XCTUnwrap(otherComposition.sections.indices.first)
        otherComposition.sections[sectionIndex].setSelection(
            MasterSelection(kind: .sourceAsset, referenceID: asset.id)
        )
        state.catalog.setMasterComposition(otherComposition)
        try store.upsert(masterComposition: otherComposition)

        XCTAssertTrue(state.catalog.songs.first(where: { $0.id == homeID })?.sections.allSatisfy { $0.assetID == nil } == true)
        XCTAssertFalse(state.canRunFilenameReanalysisSafely())

        state.reanalyzeCatalogSafely()

        XCTAssertEqual(state.catalog.assets.first(where: { $0.id == asset.id })?.songID, homeID)
        XCTAssertEqual(
            state.catalog.masterComposition(for: otherID)?.sections[sectionIndex].selection(.sourceAsset)?.referenceID,
            asset.id
        )
    }

    func testPlanSeparatesProtectedAndMovableCandidates() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Home")
        state.createSong(title: "Other")

        let homeID = try XCTUnwrap(state.catalog.songs.first(where: { $0.title == "Home" })?.id)
        let otherID = try XCTUnwrap(state.catalog.songs.first(where: { $0.title == "Other" })?.id)
        let protected = makeAsset(filename: "protected target v2.wav", role: .hook, songID: homeID)
        let movable = makeAsset(filename: "safe target v3.wav", role: .reference, songID: homeID)
        state.catalog.assets.append(contentsOf: [protected, movable])
        try store.insert(asset: protected)
        try store.insert(asset: movable)

        var otherComposition = try XCTUnwrap(state.catalog.masterComposition(for: otherID))
        let sectionIndex = try XCTUnwrap(otherComposition.sections.indices.first)
        otherComposition.sections[sectionIndex].setSelection(
            MasterSelection(kind: .sourceAsset, referenceID: protected.id)
        )
        state.catalog.setMasterComposition(otherComposition)
        try store.upsert(masterComposition: otherComposition)

        let plan = state.filenameReanalysisPlan()

        XCTAssertEqual(plan.candidateAssetIDs, Set([protected.id, movable.id]))
        XCTAssertEqual(plan.blockedAssetIDs, Set([protected.id]))
        XCTAssertEqual(plan.movableAssetIDs, Set([movable.id]))
        XCTAssertFalse(plan.canRunLegacyPass)

        XCTAssertFalse(state.reanalyzeCatalogSafely())
        XCTAssertEqual(state.catalog.assets.first(where: { $0.id == protected.id })?.songID, homeID)

        let moved = try XCTUnwrap(state.catalog.assets.first(where: { $0.id == movable.id }))
        XCTAssertNotEqual(moved.songID, homeID)
        XCTAssertEqual(
            state.catalog.songs.first(where: { $0.id == moved.songID })?.title.lowercased(),
            "safe target"
        )
        XCTAssertEqual(
            state.catalog.masterComposition(for: otherID)?.sections[sectionIndex].selection(.sourceAsset)?.referenceID,
            protected.id
        )

        let reloaded = store.loadCatalog(artistName: "STICK")
        XCTAssertEqual(reloaded.assets.first(where: { $0.id == protected.id })?.songID, homeID)
        XCTAssertEqual(reloaded.assets.first(where: { $0.id == movable.id })?.songID, moved.songID)
    }

    func testPlanBlocksLastMovableOwnedAssetWhenCanonicalSongStillReferencesExternalAsset() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Home")
        state.createSong(title: "Other")

        let homeID = try XCTUnwrap(state.catalog.songs.first(where: { $0.title == "Home" })?.id)
        let otherID = try XCTUnwrap(state.catalog.songs.first(where: { $0.title == "Other" })?.id)
        let candidate = makeAsset(filename: "target song v2.wav", role: .reference, songID: homeID)
        let external = makeAsset(filename: "Other.wav", role: .hook, songID: otherID)
        state.catalog.assets.append(contentsOf: [candidate, external])
        try store.insert(asset: candidate)
        try store.insert(asset: external)

        var homeComposition = try XCTUnwrap(state.catalog.masterComposition(for: homeID))
        let sectionIndex = try XCTUnwrap(homeComposition.sections.indices.first)
        homeComposition.sections[sectionIndex].setSelection(
            MasterSelection(kind: .sourceAsset, referenceID: external.id)
        )
        state.catalog.setMasterComposition(homeComposition)
        try store.upsert(masterComposition: homeComposition)

        let plan = state.filenameReanalysisPlan()

        XCTAssertEqual(plan.candidateAssetIDs, Set([candidate.id]))
        XCTAssertEqual(plan.blockedAssetIDs, Set([candidate.id]))
        XCTAssertTrue(plan.movableAssetIDs.isEmpty)
        XCTAssertFalse(plan.canRunLegacyPass)
    }

    func testPreflightAllowsUnreferencedFilenameRegrouping() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Home")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)

        let asset = makeAsset(filename: "target song v2.wav", role: .reference, songID: songID)
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        XCTAssertTrue(state.canRunFilenameReanalysisSafely())
        state.reanalyzeCatalogSafely()

        let moved = try XCTUnwrap(state.catalog.assets.first(where: { $0.id == asset.id }))
        XCTAssertNotEqual(moved.songID, songID)
        XCTAssertEqual(
            state.catalog.songs.first(where: { $0.id == moved.songID })?.title.lowercased(),
            "target song"
        )
    }
}
