import XCTest
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

    func testAssignPromotesOpenSlotToCandidate() throws {
        let state = try makeState()
        state.createSong(title: "Assign Test")
        let song = state.catalog.songs[0]
        let asset = Asset(id: UUID(), title: "Beat", originalFilename: "beat.wav", role: .beat,
                          createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id)
        state.catalog.assets.append(asset)

        state.assign(assetID: asset.id, sectionID: song.sections[0].id, songID: song.id)

        let section = state.catalog.songs[0].sections[0]
        XCTAssertEqual(section.assetID, asset.id)
        XCTAssertEqual(section.state, .candidate)
        XCTAssertEqual(state.catalog.events.last?.operation, .sourceSelected)
        XCTAssertEqual(state.catalog.events.last?.afterAssetID, asset.id)
    }

    func testLockingRecomputesProgress() throws {
        let state = try makeState()
        state.createSong(title: "Progress Test")
        let song = state.catalog.songs[0]
        XCTAssertEqual(state.catalog.songs[0].progress, 0)

        state.setState(.locked, sectionID: song.sections[0].id, songID: song.id)

        XCTAssertEqual(state.catalog.songs[0].progress, 0.2, accuracy: 0.001)
        XCTAssertEqual(state.catalog.events.last?.operation, .approved)
    }

    func testMoveSectionReordersAndPersists() throws {
        let state = try makeState()
        state.createSong(title: "Order Test")
        let song = state.catalog.songs[0]
        let firstID = song.sections[0].id

        state.moveSection(sectionID: firstID, songID: song.id, offset: 1)
        XCTAssertEqual(state.catalog.songs[0].sections[1].id, firstID)

        // Out-of-bounds moves are no-ops.
        let lastID = state.catalog.songs[0].sections.last!.id
        state.moveSection(sectionID: lastID, songID: song.id, offset: 1)
        XCTAssertEqual(state.catalog.songs[0].sections.last?.id, lastID)
    }

    func testRemoveSectionRecordsEvent() throws {
        let state = try makeState()
        state.createSong(title: "Remove Test")
        let song = state.catalog.songs[0]
        state.removeSection(sectionID: song.sections[0].id, songID: song.id)
        XCTAssertEqual(state.catalog.songs[0].sections.count, 4)
        XCTAssertEqual(state.catalog.events.last?.operation, .structureUpdated)
    }
}
