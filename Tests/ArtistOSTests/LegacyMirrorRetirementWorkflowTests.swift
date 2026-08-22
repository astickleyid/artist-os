import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class LegacyMirrorRetirementWorkflowTests: XCTestCase {
    func testCanonicalEditingWorkflowDoesNotRepopulateRetiredSourceMirrors() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Retirement Workflow")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let songID = song.id
        let sectionID = try XCTUnwrap(song.sections.first?.id)
        let legacyOrder = song.sections.map(\.id)

        XCTAssertTrue(song.sections.allSatisfy { $0.assetID == nil })
        XCTAssertNil(song.masterAssetID)

        let sectionSource = Asset(
            id: UUID(),
            title: "Lead v2",
            originalFilename: "lead-v2.wav",
            role: .leadVocal,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: songID
        )
        let master = Asset(
            id: UUID(),
            title: "Mix 9",
            originalFilename: "mix-9.wav",
            role: .fullMix,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: songID
        )
        state.catalog.assets.append(contentsOf: [sectionSource, master])
        try store.insert(asset: sectionSource)
        try store.insert(asset: master)

        state.approveSectionDecision(
            sectionID: sectionID,
            songID: songID,
            winner: sectionSource.id
        )
        state.approveMasterDecision(songID: songID, assetID: master.id)

        var compatibilitySong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertTrue(compatibilitySong.sections.allSatisfy { $0.assetID == nil })
        XCTAssertNil(compatibilitySong.masterAssetID)

        var composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertEqual(
            composition.sections.first { $0.id == sectionID }?.selection(.sourceAsset)?.referenceID,
            sectionSource.id
        )
        XCTAssertEqual(composition.outputAssetID, master.id)

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: songID)
        state.addCanonicalSection(name: "Post Hook", songID: songID)

        composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        let canonicalOnlyID = try XCTUnwrap(composition.sections.first { $0.name == "Post Hook" }?.id)
        XCTAssertFalse(legacyOrder.contains(canonicalOnlyID))

        state.moveCanonicalSection(sectionID: canonicalOnlyID, songID: songID, offset: -1)
        state.removeCanonicalSection(sectionID: canonicalOnlyID, songID: songID)

        compatibilitySong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertEqual(compatibilitySong.sections.map(\.id), legacyOrder)
        XCTAssertTrue(compatibilitySong.sections.allSatisfy { $0.assetID == nil })
        XCTAssertNil(compatibilitySong.masterAssetID)

        composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertNil(
            composition.sections.first { $0.id == sectionID }?.selection(.sourceAsset)?.referenceID
        )
        XCTAssertFalse(composition.sections.contains { $0.id == canonicalOnlyID })
        XCTAssertEqual(composition.outputAssetID, master.id)

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedSong = try XCTUnwrap(reloaded.songs.first { $0.id == songID })
        XCTAssertEqual(persistedSong.sections.map(\.id), legacyOrder)
        XCTAssertTrue(persistedSong.sections.allSatisfy { $0.assetID == nil })
        XCTAssertNil(persistedSong.masterAssetID)

        let persistedComposition = try XCTUnwrap(
            reloaded.masterCompositions.first { $0.songID == songID }
        )
        XCTAssertNil(
            persistedComposition.sections.first { $0.id == sectionID }?.selection(.sourceAsset)?.referenceID
        )
        XCTAssertFalse(persistedComposition.sections.contains { $0.id == canonicalOnlyID })
        XCTAssertEqual(persistedComposition.outputAssetID, master.id)
    }
}
