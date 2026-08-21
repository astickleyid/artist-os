import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class AppStateTests: XCTestCase {
    private func makeState() throws -> AppState {
        AppState(store: CatalogStore(database: try AppDatabase.inMemory()), seedIfNeeded: false)
    }

    func testCreateSongRecordsEvent() throws {
        let state = try makeState()
        XCTAssertTrue(state.catalog.songs.isEmpty)
        state.createSong(title: "  Night Drive  ")
        XCTAssertEqual(state.catalog.songs.count, 1)
        XCTAssertEqual(state.catalog.songs[0].title, "Night Drive")
        XCTAssertEqual(state.selectedSongID, state.catalog.songs[0].id)
        XCTAssertEqual(state.catalog.events.count, 1)
        XCTAssertEqual(state.catalog.events[0].operation, .structureUpdated)
    }
}

extension AppStateTests {
    func testRenameSongRecordsEvent() throws {
        let state = AppState(
            store: CatalogStore(database: try AppDatabase.inMemory()),
            seedIfNeeded: false, enableWatching: false
        )
        state.createSong(title: "Old Name")
        let id = state.catalog.songs[0].id

        state.renameSong(id: id, to: "  New Name ")
        XCTAssertEqual(state.catalog.songs[0].title, "New Name")
        XCTAssertTrue(state.catalog.events.last?.summary.contains("Renamed") ?? false)

        // Renaming to the same title is a no-op (no event spam).
        let count = state.catalog.events.count
        state.renameSong(id: id, to: "New Name")
        XCTAssertEqual(state.catalog.events.count, count)
    }
}
