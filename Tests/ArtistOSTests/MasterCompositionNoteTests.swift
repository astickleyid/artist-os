import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class MasterCompositionNoteTests: XCTestCase {
    func testUpdatingNotePersistsCanonicalAndLegacyWithoutInventingHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Annotated Song")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = try XCTUnwrap(song.sections.first?.id)
        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count

        state.updateCanonicalSectionNote(
            "Keep the breath before the hook.",
            sectionID: sectionID,
            songID: song.id
        )

        let liveSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        XCTAssertEqual(
            liveSong.sections.first { $0.id == sectionID }?.note,
            "Keep the breath before the hook."
        )

        let liveComposition = try XCTUnwrap(state.catalog.masterComposition(for: song.id))
        XCTAssertEqual(
            liveComposition.sections.first { $0.id == sectionID }?.note,
            "Keep the breath before the hook."
        )
        XCTAssertEqual(state.catalog.events.count, eventCount)
        XCTAssertEqual(state.catalog.decisions.count, decisionCount)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(
            reloaded.songs.first { $0.id == song.id }?
                .sections.first { $0.id == sectionID }?.note,
            "Keep the breath before the hook."
        )
        XCTAssertEqual(
            reloaded.masterComposition(for: song.id)?
                .sections.first { $0.id == sectionID }?.note,
            "Keep the breath before the hook."
        )
        XCTAssertEqual(reloaded.events.count, eventCount)
        XCTAssertEqual(reloaded.decisions.count, decisionCount)
    }

    func testSavingUnchangedNoteIsANoOp() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "No-op Note")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = try XCTUnwrap(song.sections.first?.id)

        state.updateCanonicalSectionNote("", sectionID: sectionID, songID: song.id)

        XCTAssertTrue(state.catalog.masterCompositions.isEmpty)
    }
}