import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalMasterStructureEditingTests: XCTestCase {
    func testAddingSlotWritesCanonicalHistoryWithoutExtendingLegacyMembership() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Structure")
        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let originalLegacyIDs = try XCTUnwrap(state.catalog.songs.first?.sections.map(\.id))
        let originalCount = originalLegacyIDs.count
        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count

        state.addCanonicalSection(name: "Verse 2", songID: songID)

        let song = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertEqual(song.sections.map(\.id), originalLegacyIDs)

        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertEqual(composition.sections.count, originalCount + 1)
        let addedCanonical = try XCTUnwrap(composition.sections.last)
        XCTAssertEqual(addedCanonical.name, "Verse 2")
        XCTAssertFalse(song.sections.contains { $0.id == addedCanonical.id })

        XCTAssertEqual(state.catalog.events.count, eventCount + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionCount + 1)
        let event = try XCTUnwrap(state.catalog.events.last)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(event.operation, .structureUpdated)
        XCTAssertEqual(decision.action, .approved)
        XCTAssertEqual(decision.relatedEventIDs, [event.id])
        XCTAssertTrue(decision.reason?.contains("Verse 2") == true)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs.first { $0.id == songID }?.sections.map(\.id), originalLegacyIDs)
        XCTAssertEqual(reloaded.masterCompositions.first { $0.songID == songID }?.sections.last?.id, addedCanonical.id)
        XCTAssertTrue(reloaded.events.contains { $0.id == event.id })
        XCTAssertTrue(reloaded.decisions.contains { $0.id == decision.id })
    }

    func testRemovingSlotChangesCanonicalTruthWithoutShrinkingLegacyMembership() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Remove")
        let song = try XCTUnwrap(state.catalog.songs.first)
        let songID = song.id
        let sectionID = try XCTUnwrap(song.sections.first?.id)

        let canonicalAsset = Asset(
            id: UUID(),
            title: "Canonical Intro Source",
            originalFilename: "intro-canonical.wav",
            role: .fullMix,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: songID
        )
        let legacyAsset = Asset(
            id: UUID(),
            title: "Legacy Intro Source",
            originalFilename: "intro-legacy.wav",
            role: .fullMix,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: songID
        )
        state.catalog.assets.append(contentsOf: [canonicalAsset, legacyAsset])
        try store.insert(asset: canonicalAsset)
        try store.insert(asset: legacyAsset)
        state.approveSectionDecision(sectionID: sectionID, songID: songID, winner: canonicalAsset.id)

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = legacyAsset.id
        try store.upsert(song: state.catalog.songs[songIndex])

        let legacyBeforeRemoval = state.catalog.songs[songIndex].sections
        let decisionsBeforeRemoval = state.catalog.decisions.count
        let eventsBeforeRemoval = state.catalog.events.count

        state.removeCanonicalSection(sectionID: sectionID, songID: songID)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertEqual(updatedSong.sections, legacyBeforeRemoval)
        XCTAssertEqual(updatedSong.sections.first { $0.id == sectionID }?.assetID, legacyAsset.id)
        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertFalse(composition.sections.contains { $0.id == sectionID })

        XCTAssertTrue(state.catalog.assets.contains { $0.id == canonicalAsset.id })
        XCTAssertTrue(state.catalog.assets.contains { $0.id == legacyAsset.id })
        XCTAssertEqual(state.catalog.events.count, eventsBeforeRemoval + 1)
        XCTAssertEqual(state.catalog.decisions.count, decisionsBeforeRemoval + 1)

        let removalEvent = try XCTUnwrap(state.catalog.events.last)
        let removalDecision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(removalEvent.beforeAssetID, canonicalAsset.id)
        XCTAssertEqual(removalDecision.action, .reverted)
        XCTAssertEqual(Set(removalDecision.rejectedAssetIDs), Set([canonicalAsset.id]))
        XCTAssertEqual(removalDecision.relatedEventIDs, [removalEvent.id])

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs.first { $0.id == songID }?.sections, legacyBeforeRemoval)
        XCTAssertEqual(
            reloaded.songs.first { $0.id == songID }?.sections.first { $0.id == sectionID }?.assetID,
            legacyAsset.id
        )
        XCTAssertFalse(reloaded.masterCompositions.first { $0.songID == songID }?.sections.contains { $0.id == sectionID } ?? true)
        XCTAssertTrue(reloaded.assets.contains { $0.id == canonicalAsset.id })
        XCTAssertTrue(reloaded.assets.contains { $0.id == legacyAsset.id })
        XCTAssertTrue(reloaded.events.contains { $0.id == removalEvent.id })
        XCTAssertTrue(reloaded.decisions.contains { $0.id == removalDecision.id })
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
