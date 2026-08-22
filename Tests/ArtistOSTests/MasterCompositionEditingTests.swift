import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class MasterCompositionEditingTests: XCTestCase {
    func testClearingCanonicalSourcePersistsDecisionEventWithoutRewritingLegacyMirror() throws {
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

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == song.id })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = asset.id
        state.catalog.songs[songIndex].sections[sectionIndex].state = .locked
        state.catalog.songs[songIndex].sections[sectionIndex].confidence = 0.88
        try store.upsert(song: state.catalog.songs[songIndex])

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        let updatedSection = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        XCTAssertEqual(updatedSection.assetID, asset.id)
        XCTAssertEqual(updatedSection.state, .locked)
        XCTAssertEqual(updatedSection.confidence, 0.88, accuracy: 0.0001)

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
        let persistedLegacy = try XCTUnwrap(persistedSong.sections.first { $0.id == sectionID })
        XCTAssertEqual(persistedLegacy.assetID, asset.id)
        XCTAssertEqual(persistedLegacy.state, .locked)
        XCTAssertEqual(persistedLegacy.confidence, 0.88, accuracy: 0.0001)
        let persistedComposition = try XCTUnwrap(reloaded.masterCompositions.first { $0.songID == song.id })
        let persistedCanonical = try XCTUnwrap(persistedComposition.sections.first { $0.id == sectionID })
        XCTAssertNil(persistedCanonical.selection(.sourceAsset))
        XCTAssertEqual(persistedCanonical.state, .open)
        XCTAssertEqual(persistedCanonical.confidence, 0)
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

        let legacySection = try XCTUnwrap(
            state.catalog.songs.first { $0.id == song.id }?.sections.first { $0.id == sectionID }
        )
        XCTAssertEqual(legacySection.assetID, staleLegacyAsset.id)
        XCTAssertNil(
            state.catalog.masterCompositions.first { $0.songID == song.id }?.sections.first { $0.id == sectionID }
        )

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(
            reloaded.songs.first { $0.id == song.id }?.sections.first { $0.id == sectionID }?.assetID,
            staleLegacyAsset.id
        )
        XCTAssertNil(
            reloaded.masterCompositions.first { $0.songID == song.id }?.sections.first { $0.id == sectionID }
        )
    }

    func testRemovingCanonicalSectionDerivesProgressFromCanonicalComposition() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Canonical Structural Progress")

        let song = try XCTUnwrap(state.catalog.songs.first)
        let removedSectionID = song.sections[0].id
        let canonical = try XCTUnwrap(state.catalog.masterComposition(for: song.id))
        state.catalog.setMasterComposition(canonical)
        try store.upsert(masterComposition: canonical)

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == song.id })
        for index in state.catalog.songs[songIndex].sections.indices {
            state.catalog.songs[songIndex].sections[index].state = .locked
        }
        state.catalog.songs[songIndex].progress = 1
        state.catalog.songs[songIndex].risk = "Master locked"
        try store.upsert(song: state.catalog.songs[songIndex])

        state.removeCanonicalSection(sectionID: removedSectionID, songID: song.id)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        XCTAssertEqual(updatedSong.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(updatedSong.risk, "In assembly")

        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == song.id })
        XCTAssertEqual(updatedComposition.sections.count, canonical.sections.count - 1)
        XCTAssertTrue(updatedComposition.sections.allSatisfy { $0.state == .open })

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedSong = try XCTUnwrap(reloaded.songs.first { $0.id == song.id })
        XCTAssertEqual(persistedSong.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(persistedSong.risk, "In assembly")
    }

    func testClearingCanonicalEmptySourceLeavesStaleLegacyMirrorUntouchedWithoutHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Retire Empty Canonical Mirror")

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

        let decisionsBefore = state.catalog.decisions.count
        let eventsBefore = state.catalog.events.count
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == song.id })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = asset.id
        state.catalog.songs[songIndex].sections[sectionIndex].state = .locked
        state.catalog.songs[songIndex].sections[sectionIndex].confidence = 0.97
        try store.upsert(song: state.catalog.songs[songIndex])

        state.clearCanonicalSectionSource(sectionID: sectionID, songID: song.id)

        let untouchedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        let untouchedLegacy = try XCTUnwrap(untouchedSong.sections.first { $0.id == sectionID })
        XCTAssertEqual(untouchedLegacy.assetID, asset.id)
        XCTAssertEqual(untouchedLegacy.state, .locked)
        XCTAssertEqual(untouchedLegacy.confidence, 0.97, accuracy: 0.0001)
        XCTAssertEqual(state.catalog.events.count, eventsBefore)
        XCTAssertEqual(state.catalog.decisions.count, decisionsBefore)

        let canonical = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == song.id })
        let canonicalSection = try XCTUnwrap(canonical.sections.first { $0.id == sectionID })
        XCTAssertNil(canonicalSection.selection(.sourceAsset))
        XCTAssertEqual(canonicalSection.state, .open)
        XCTAssertEqual(canonicalSection.confidence, 0)

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedLegacy = try XCTUnwrap(
            reloaded.songs.first { $0.id == song.id }?.sections.first { $0.id == sectionID }
        )
        XCTAssertEqual(persistedLegacy.assetID, asset.id)
        XCTAssertEqual(persistedLegacy.state, .locked)
        XCTAssertEqual(persistedLegacy.confidence, 0.97, accuracy: 0.0001)
        XCTAssertEqual(reloaded.events.count, eventsBefore)
        XCTAssertEqual(reloaded.decisions.count, decisionsBefore)
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
