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
