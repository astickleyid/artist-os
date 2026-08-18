import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalMasterStructureEditingTests: XCTestCase {
    func testAddingSlotWritesCanonicalLegacyEventAndDecisionTogether() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Structure")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let originalCount = try XCTUnwrap(state.catalog.songs.first?.sections.count)
        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count

        state.addCanonicalSection(name: "Verse 2", songID: songID)

        let song = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertEqual(song.sections.count, originalCount + 1)
        let addedLegacy = try XCTUnwrap(song.sections.last)
        XCTAssertEqual(addedLegacy.name, "Verse 2")

        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertEqual(composition.sections.count, originalCount + 1)
        let addedCanonical = try XCTUnwrap(composition.sections.last)
        XCTAssertEqual(addedCanonical.id, addedLegacy.id)
        XCTAssertEqual(addedCanonical.name, "Verse 2")

        XCTAssertEqual(state.catalog.events.count, eventCount + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionCount + 1)
        let event = try XCTUnwrap(state.catalog.events.last)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(event.operation, .structureUpdated)
        XCTAssertEqual(decision.action, .approved)
        XCTAssertEqual(decision.relatedEventIDs, [event.id])
        XCTAssertTrue(decision.reason?.contains("Verse 2") == true)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs.first { $0.id == songID }?.sections.last?.id, addedLegacy.id)
        XCTAssertEqual(reloaded.masterCompositions.first { $0.songID == songID }?.sections.last?.id, addedLegacy.id)
        XCTAssertEqual(reloaded.events.last?.id, event.id)
        XCTAssertEqual(reloaded.decisions.last?.id, decision.id)
    }

    func testRemovingSlotRemovesCurrentCanonicalTruthButPreservesHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Remove")
        let song = try XCTUnwrap(state.catalog.songs.first)
        let songID = song.id
        let sectionID = try XCTUnwrap(song.sections.first?.id)

        let asset = Asset(
            id: UUID(),
            title: "Intro Source",
            originalFilename: "intro.wav",
            role: .fullMix,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: songID
        )
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)
        state.approveSectionDecision(sectionID: sectionID, songID: songID, winner: asset.id)
        let decisionsBeforeRemoval = state.catalog.decisions.count
        let eventsBeforeRemoval = state.catalog.events.count

        state.removeCanonicalSection(sectionID: sectionID, songID: songID)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertFalse(updatedSong.sections.contains { $0.id == sectionID })
        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertFalse(composition.sections.contains { $0.id == sectionID })

        XCTAssertTrue(state.catalog.assets.contains { $0.id == asset.id })
        XCTAssertEqual(state.catalog.events.count, eventsBeforeRemoval + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionsBeforeRemoval + 1)

        let removalEvent = try XCTUnwrap(state.catalog.events.last)
        let removalDecision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(removalEvent.beforeAssetID, asset.id)
        XCTAssertEqual(removalDecision.action, .reverted)
        XCTAssertEqual(removalDecision.rejectedAssetIDs, [asset.id])
        XCTAssertEqual(removalDecision.relatedEventIDs, [removalEvent.id])

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertFalse(reloaded.songs.first { $0.id == songID }?.sections.contains { $0.id == sectionID } ?? true)
        XCTAssertFalse(reloaded.masterCompositions.first { $0.songID == songID }?.sections.contains { $0.id == sectionID } ?? true)
        XCTAssertTrue(reloaded.assets.contains { $0.id == asset.id })
    }

    func testBlankSlotNameDoesNotCreateCanonicalHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Noop")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let sectionCount = try XCTUnwrap(state.catalog.songs.first?.sections.count)
        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count

        state.addCanonicalSection(name: "   ", songID: songID)

        XCTAssertEqual(state.catalog.songs.first?.sections.count, sectionCount)
        XCTAssertEqual(state.catalog.events.count, eventCount)
        XCTAssertEqual(state.catalog.decisions.count, decisionCount)
        XCTAssertTrue(state.catalog.masterCompositions.isEmpty)
    }
}
