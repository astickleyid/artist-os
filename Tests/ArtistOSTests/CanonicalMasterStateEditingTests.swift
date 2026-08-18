import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalMasterStateEditingTests: XCTestCase {
    func testMoveCanonicalSectionKeepsCanonicalAndLegacyOrderAligned() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Order")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        state.addCanonicalSection(name: "Verse 2", songID: songID)

        let before = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let movedID = try XCTUnwrap(before.sections.last?.id)
        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count

        state.moveCanonicalSection(sectionID: movedID, songID: songID, offset: -1)

        let song = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertEqual(song.sections.map(\.id), composition.sections.map(\.id))
        XCTAssertEqual(song.sections[song.sections.count - 2].id, movedID)
        XCTAssertEqual(state.catalog.events.count, eventCount + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionCount + 1)

        let event = try XCTUnwrap(state.catalog.events.last)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(event.operation, .structureUpdated)
        XCTAssertEqual(decision.action, .approved)
        XCTAssertEqual(decision.relatedEventIDs, [event.id])

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(
            reloaded.songs.first { $0.id == songID }?.sections.map(\.id),
            reloaded.masterCompositions.first { $0.songID == songID }?.sections.map(\.id)
        )
    }

    func testMoveCanonicalSectionHealsOrderOnlyLegacyDivergence() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Diverged Order")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        state.addCanonicalSection(name: "Verse 2", songID: songID)

        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertGreaterThanOrEqual(composition.sections.count, 3)
        let movedID = composition.sections.last!.id

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        state.catalog.songs[songIndex].sections.swapAt(0, 1)
        try store.upsert(song: state.catalog.songs[songIndex])
        XCTAssertNotEqual(
            state.catalog.songs[songIndex].sections.map(\.id),
            composition.sections.map(\.id)
        )

        state.moveCanonicalSection(sectionID: movedID, songID: songID, offset: -1)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertEqual(updatedSong.sections.map(\.id), updatedComposition.sections.map(\.id))
        XCTAssertEqual(updatedComposition.sections[updatedComposition.sections.count - 2].id, movedID)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(
            reloaded.songs.first { $0.id == songID }?.sections.map(\.id),
            reloaded.masterCompositions.first { $0.songID == songID }?.sections.map(\.id)
        )
    }

    func testSetCanonicalStateUpdatesBothModelsAndPreservesSourceLink() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "State")
        let song = try XCTUnwrap(state.catalog.songs.first)
        let songID = song.id
        let sectionID = try XCTUnwrap(song.sections.first?.id)
        let asset = Asset(
            id: UUID(), title: "Source", originalFilename: "source.wav",
            role: .fullMix, createdAt: Date(), duration: nil,
            localURLBookmark: nil, songID: songID
        )
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)
        state.approveSectionDecision(sectionID: sectionID, songID: songID, winner: asset.id)

        state.setCanonicalSectionState(.needsDecision, sectionID: sectionID, songID: songID)
        state.setCanonicalSectionState(.locked, sectionID: sectionID, songID: songID)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let legacy = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        let canonical = try XCTUnwrap(composition.sections.first { $0.id == sectionID })
        XCTAssertEqual(legacy.state, .locked)
        XCTAssertEqual(canonical.state, .locked)
        XCTAssertGreaterThanOrEqual(legacy.confidence, 0.9)
        XCTAssertGreaterThanOrEqual(canonical.confidence, 0.9)
        XCTAssertEqual(canonical.selection(.sourceAsset)?.referenceID, asset.id)

        let approvalDecision = try XCTUnwrap(state.catalog.decisions.last)
        let approvalEvent = try XCTUnwrap(state.catalog.events.last)
        XCTAssertEqual(approvalDecision.action, .approved)
        XCTAssertEqual(approvalDecision.selectedAssetID, asset.id)
        XCTAssertEqual(approvalDecision.relatedEventIDs, [approvalEvent.id])
        XCTAssertEqual(approvalEvent.operation, .approved)
        XCTAssertEqual(approvalEvent.beforeAssetID, asset.id)
        XCTAssertEqual(approvalEvent.afterAssetID, asset.id)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(
            reloaded.songs.first { $0.id == songID }?.sections.first { $0.id == sectionID }?.state,
            .locked
        )
        XCTAssertEqual(
            reloaded.masterCompositions.first { $0.songID == songID }?.sections.first { $0.id == sectionID }?.state,
            .locked
        )
    }
}
