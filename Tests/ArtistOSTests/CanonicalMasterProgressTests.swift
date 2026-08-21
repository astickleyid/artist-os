import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalMasterProgressTests: XCTestCase {
    func testStateEditDerivesSongProgressFromCanonicalCompositionWhenLegacyStateIsStale() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Canonical Progress")

        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })

        var composition = try XCTUnwrap(state.catalog.masterComposition(for: songID))
        XCTAssertGreaterThanOrEqual(composition.sections.count, 2)

        // Persist canonical truth that intentionally diverges from the legacy
        // compatibility mirror. Artist-facing progress/risk must follow this.
        for index in composition.sections.indices {
            composition.sections[index].state = .open
        }
        composition.sections[0].state = .needsDecision
        composition.updatedAt = Date()
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        for index in state.catalog.songs[songIndex].sections.indices {
            state.catalog.songs[songIndex].sections[index].state = .locked
        }
        state.catalog.songs[songIndex].progress = 1
        state.catalog.songs[songIndex].risk = "Master locked"
        try store.upsert(song: state.catalog.songs[songIndex])

        let targetSectionID = composition.sections[1].id
        state.setCanonicalSectionState(.locked, sectionID: targetSectionID, songID: songID)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        let lockedCount = updatedComposition.sections.filter { $0.state == .locked }.count
        let expectedProgress = Double(lockedCount) / Double(updatedComposition.sections.count)

        XCTAssertEqual(lockedCount, 1)
        XCTAssertEqual(updatedSong.progress, expectedProgress, accuracy: 0.000_001)
        XCTAssertNotEqual(updatedSong.progress, 1)
        XCTAssertEqual(updatedSong.risk, "\(updatedComposition.sections[0].name) decision unresolved")
        XCTAssertNotEqual(updatedSong.risk, "Master locked")

        let reloaded = store.loadCatalog(artistName: "T")
        let reloadedSong = try XCTUnwrap(reloaded.songs.first { $0.id == songID })
        XCTAssertEqual(reloadedSong.progress, expectedProgress, accuracy: 0.000_001)
        XCTAssertEqual(reloadedSong.risk, "\(updatedComposition.sections[0].name) decision unresolved")
    }
}
