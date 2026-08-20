import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class MasterCompositionEditingTests: XCTestCase {
    func testClearingCanonicalSourcePersistsDecisionEventAndLegacyMirror() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Clear Source")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = song.sections[0].id
        let asset = Asset(
            id: UUID(),
            title: "Lead 4",
            originalFilename: "lead4.wav",
            role: .leadVocal,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: song.id
        )
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        state.approveSectionDecision(
            sectionID: sectionID,
            songID: song.id,
            winner: asset.id
        )
        let decisionCount = state.catalog.decisions.count
        let eventCount = state.catalog.events.count

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        let updatedSection = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        XCTAssertNil(updatedSection.assetID)
        XCTAssertEqual(updatedSection.state, .open)
        XCTAssertEqual(updatedSection.confidence, 0)

        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == song.id })
        let canonicalSection = try XCTUnwrap(composition.sections.first { $0.id == sectionID })
        XCTAssertNil(canonicalSection.selection(.sourceAsset))
        XCTAssertEqual(canonicalSection.state, .open)
        XCTAssertEqual(canonicalSection.confidence, 0)

        XCTAssertEqual(state.catalog.decisions.count, decisionCount + 1)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(decision.action, .reverted)
        XCTAssertNil(decision.selectedAssetID)
        XCTAssertEqual(decision.rejectedAssetIDs, [asset.id])

        XCTAssertEqual(state.catalog.events.count, eventCount + 1)
        let event = try XCTUnwrap(state.catalog.events.last)
        XCTAssertEqual(event.operation, .structureUpdated)
        XCTAssertEqual(event.beforeAssetID, asset.id)
        XCTAssertNil(event.afterAssetID)
        XCTAssertEqual(decision.relatedEventIDs, [event.id])

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedSong = try XCTUnwrap(reloaded.songs.first { $0.id == song.id })
        XCTAssertNil(persistedSong.sections.first { $0.id == sectionID }?.assetID)
        let persistedComposition = try XCTUnwrap(reloaded.masterCompositions.first { $0.songID == song.id })
        XCTAssertNil(persistedComposition.sections.first { $0.id == sectionID }?.selection(.sourceAsset))
        XCTAssertEqual(reloaded.decisions.last?.id, decision.id)
        XCTAssertEqual(reloaded.events.last?.id, event.id)
    }

    func testClearingCanonicalSourceIgnoresStaleLegacySourceInHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Clear Divergence")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = song.sections[0].id
        let canonicalAsset = Asset(
            id: UUID(),
            title: "Canonical Lead",
            originalFilename: "canonical.wav",
            role: .leadVocal,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: song.id
        )
        let staleLegacyAsset = Asset(
            id: UUID(),
            title: "Stale Legacy Lead",
            originalFilename: "legacy.wav",
            role: .leadVocal,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: song.id
        )
        for asset in [canonicalAsset, staleLegacyAsset] {
            state.catalog.assets.append(asset)
            try store.insert(asset: asset)
        }

        state.approveSectionDecision(
            sectionID: sectionID,
            songID: song.id,
            winner: canonicalAsset.id
        )
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == song.id })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = staleLegacyAsset.id

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        let event = try XCTUnwrap(state.catalog.events.last)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(event.beforeAssetID, canonicalAsset.id)
        XCTAssertEqual(decision.rejectedAssetIDs, [canonicalAsset.id])
        XCTAssertFalse(decision.rejectedAssetIDs.contains(staleLegacyAsset.id))
    }

    func testRemovingCanonicalSectionIgnoresStaleLegacySourceInHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Remove Divergence")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = song.sections[0].id
        let canonicalAsset = Asset(
            id: UUID(),
            title: "Canonical Hook",
            originalFilename: "hook-canonical.wav",
            role: .hook,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: song.id
        )
        let staleLegacyAsset = Asset(
            id: UUID(),
            title: "Stale Hook",
            originalFilename: "hook-stale.wav",
            role: .hook,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: song.id
        )
        for asset in [canonicalAsset, staleLegacyAsset] {
            state.catalog.assets.append(asset)
            try store.insert(asset: asset)
        }

        state.approveSectionDecision(
            sectionID: sectionID,
            songID: song.id,
            winner: canonicalAsset.id
        )
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == song.id })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = staleLegacyAsset.id

        state.removeCanonicalSection(sectionID: sectionID, songID: song.id)

        let event = try XCTUnwrap(state.catalog.events.last)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(event.beforeAssetID, canonicalAsset.id)
        XCTAssertEqual(decision.rejectedAssetIDs, [canonicalAsset.id])
        XCTAssertFalse(decision.rejectedAssetIDs.contains(staleLegacyAsset.id))
        XCTAssertNil(state.catalog.songs.first { $0.id == song.id }?.sections.first { $0.id == sectionID })
    }

    func testClearingCanonicalEmptySourceHealsStaleLegacyMirrorWithoutHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Heal Empty Canonical")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = song.sections[0].id
        let asset = Asset(
            id: UUID(),
            title: "Old Mirror Source",
            originalFilename: "old-mirror.wav",
            role: .leadVocal,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil,
            songID: song.id
        )
        state.catalog.assets.append(asset)
        try store.insert(asset: asset)

        state.approveSectionDecision(sectionID: sectionID, songID: song.id, winner: asset.id)
        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        let decisionsBeforeHealing = state.catalog.decisions.count
        let eventsBeforeHealing = state.catalog.events.count
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == song.id })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = asset.id
        try store.upsert(song: state.catalog.songs[songIndex])

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        let healedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        XCTAssertNil(healedSong.sections.first { $0.id == sectionID }?.assetID)
        XCTAssertEqual(state.catalog.events.count, eventsBeforeHealing)
        XCTAssertEqual(state.catalog.decisions.count, decisionsBeforeHealing)

        let canonical = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == song.id })
        XCTAssertNil(canonical.sections.first { $0.id == sectionID }?.selection(.sourceAsset))

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertNil(reloaded.songs.first { $0.id == song.id }?.sections.first { $0.id == sectionID }?.assetID)
        XCTAssertEqual(reloaded.events.count, eventsBeforeHealing)
        XCTAssertEqual(reloaded.decisions.count, decisionsBeforeHealing)
    }

    func testClearingEmptySourceDoesNotCreateHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Already Empty")
        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = song.sections[0].id
        let decisionsBefore = state.catalog.decisions.count
        let eventsBefore = state.catalog.events.count

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        XCTAssertEqual(state.catalog.decisions.count, decisionsBefore)
        XCTAssertEqual(state.catalog.events.count, eventsBefore)
        XCTAssertTrue(state.catalog.masterCompositions.isEmpty)
    }
}
