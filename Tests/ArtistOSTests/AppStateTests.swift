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

    func testDeleteSongRemovesEverythingAndFixesSelection() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Keeper")
        state.createSong(title: "Doomed")
        let doomed = state.catalog.songs[1]
        let asset = Asset(id: UUID(), title: "A", originalFilename: "a.wav", role: .beat,
                          createdAt: Date(), duration: nil, localURLBookmark: nil,
                          songID: doomed.id)
        state.catalog.assets.append(asset)
        state.selectedSongID = doomed.id

        state.deleteSong(id: doomed.id)

        XCTAssertEqual(state.catalog.songs.map(\.title), ["Keeper"])
        XCTAssertTrue(state.catalog.assets.isEmpty)
        XCTAssertFalse(state.catalog.events.contains { $0.songID == doomed.id })
        XCTAssertEqual(state.selectedSongID, state.catalog.songs[0].id)

        // Persisted: a fresh load sees the same state.
        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs.count, 1)
        XCTAssertFalse(reloaded.events.contains { $0.songID == doomed.id })
    }
}
