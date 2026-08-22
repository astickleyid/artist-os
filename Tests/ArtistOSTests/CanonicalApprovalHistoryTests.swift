import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalApprovalHistoryTests: XCTestCase {
    func testSectionApprovalUsesCanonicalPriorSourceWhenLegacyMirrorDiverges() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Canonical Approval")

        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let sectionID = try XCTUnwrap(state.catalog.songs.first?.sections.first?.id)
        let canonicalPrior = Asset(
            id: UUID(), title: "Canonical Prior", originalFilename: "canonical.wav", role: .leadVocal,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        let newWinner = Asset(
            id: UUID(), title: "New Winner", originalFilename: "winner.wav", role: .leadVocal,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        state.catalog.assets.append(contentsOf: [canonicalPrior, newWinner])
        try store.insert(asset: canonicalPrior)
        try store.insert(asset: newWinner)

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        let sectionIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })
        state.catalog.songs[songIndex].sections[sectionIndex].assetID = newWinner.id
        state.catalog.songs[songIndex].sections[sectionIndex].state = .locked
        try store.upsert(song: state.catalog.songs[songIndex])

        var composition = MasterComposition.projected(from: state.catalog.songs[songIndex])
        let canonicalIndex = try XCTUnwrap(composition.sections.firstIndex { $0.id == sectionID })
        composition.sections[canonicalIndex].setSelection(MasterSelection(
            kind: .sourceAsset,
            referenceID: canonicalPrior.id
        ))
        composition.sections[canonicalIndex].state = .needsDecision
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count
        state.approveSectionDecision(sectionID: sectionID, songID: songID, winner: newWinner.id)

        XCTAssertEqual(state.catalog.decisions.count, decisionCount + 1, "Canonical divergence must not be suppressed by a matching legacy mirror")
        let newEvents = Array(state.catalog.events.dropFirst(eventCount))
        XCTAssertEqual(newEvents.map(\.operation), [.sourceSelected, .approved])
        XCTAssertEqual(newEvents.first?.beforeAssetID, canonicalPrior.id)
        XCTAssertNotEqual(newEvents.first?.beforeAssetID, newWinner.id)

        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        let updatedCanonicalSection = try XCTUnwrap(updatedComposition.sections.first { $0.id == sectionID })
        XCTAssertEqual(updatedCanonicalSection.selection(.sourceAsset)?.referenceID, newWinner.id)
        XCTAssertEqual(updatedCanonicalSection.state, .locked)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let updatedLegacySection = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        XCTAssertEqual(updatedLegacySection.assetID, newWinner.id, "Approval no longer rewrites legacy source mirrors")

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedComposition = try XCTUnwrap(reloaded.masterCompositions.first { $0.songID == songID })
        let persistedSection = try XCTUnwrap(persistedComposition.sections.first { $0.id == sectionID })
        XCTAssertEqual(persistedSection.selection(.sourceAsset)?.referenceID, newWinner.id)
    }

    func testMasterApprovalUsesCanonicalPriorOutputWhenLegacyMirrorDiverges() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Canonical Master Approval")

        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let canonicalPrior = Asset(
            id: UUID(), title: "Canonical Master", originalFilename: "canonical-master.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        let newWinner = Asset(
            id: UUID(), title: "New Master", originalFilename: "new-master.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        state.catalog.assets.append(contentsOf: [canonicalPrior, newWinner])
        try store.insert(asset: canonicalPrior)
        try store.insert(asset: newWinner)

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        state.catalog.songs[songIndex].masterAssetID = newWinner.id
        try store.upsert(song: state.catalog.songs[songIndex])

        var composition = MasterComposition.projected(from: state.catalog.songs[songIndex])
        composition.outputAssetID = canonicalPrior.id
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count
        state.approveMasterDecision(songID: songID, assetID: newWinner.id)

        XCTAssertEqual(state.catalog.decisions.count, decisionCount + 1, "Canonical master divergence must not be suppressed by a matching legacy mirror")
        let newEvents = Array(state.catalog.events.dropFirst(eventCount))
        XCTAssertEqual(newEvents.count, 1)
        XCTAssertEqual(newEvents.first?.operation, .approved)
        XCTAssertEqual(newEvents.first?.beforeAssetID, canonicalPrior.id)
        XCTAssertEqual(newEvents.first?.afterAssetID, newWinner.id)

        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(decision.target, .master)
        XCTAssertEqual(decision.selectedAssetID, newWinner.id)
        XCTAssertEqual(decision.relatedEventIDs, newEvents.map(\.id))

        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        XCTAssertEqual(updatedComposition.outputAssetID, newWinner.id)
        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        XCTAssertEqual(updatedSong.masterAssetID, newWinner.id, "Approval no longer rewrites legacy master mirrors")

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.masterCompositions.first { $0.songID == songID }?.outputAssetID, newWinner.id)
    }

    func testMasterApprovalDoesNotHealStaleLegacyMirrorOrInventHistory() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Master Mirror Retirement")

        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let canonicalMaster = Asset(
            id: UUID(), title: "Canonical Master", originalFilename: "canonical-master.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        let staleLegacyMaster = Asset(
            id: UUID(), title: "Stale Legacy Master", originalFilename: "stale-master.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: songID
        )
        state.catalog.assets.append(contentsOf: [canonicalMaster, staleLegacyMaster])
        try store.insert(asset: canonicalMaster)
        try store.insert(asset: staleLegacyMaster)

        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        state.catalog.songs[songIndex].masterAssetID = staleLegacyMaster.id
        try store.upsert(song: state.catalog.songs[songIndex])

        var composition = MasterComposition.projected(from: state.catalog.songs[songIndex])
        composition.outputAssetID = canonicalMaster.id
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        let eventCount = state.catalog.events.count
        let decisionCount = state.catalog.decisions.count
        state.approveMasterDecision(songID: songID, assetID: canonicalMaster.id)

        XCTAssertEqual(state.catalog.events.count, eventCount, "A canonical no-op must not invent a factual event")
        XCTAssertEqual(state.catalog.decisions.count, decisionCount, "A canonical no-op must not invent artist intent")
        XCTAssertEqual(state.catalog.songs[songIndex].masterAssetID, staleLegacyMaster.id, "Approval must not heal retired compatibility mirrors")
        XCTAssertEqual(
            state.catalog.masterCompositions.first { $0.songID == songID }?.outputAssetID,
            canonicalMaster.id
        )
        XCTAssertTrue(try store.canonicalSyncOutbox().isEmpty, "Sync-off canonical no-op should not enqueue network work")

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs.first { $0.id == songID }?.masterAssetID, staleLegacyMaster.id)
        XCTAssertEqual(reloaded.masterCompositions.first { $0.songID == songID }?.outputAssetID, canonicalMaster.id)
        XCTAssertEqual(reloaded.events.count, eventCount)
        XCTAssertEqual(reloaded.decisions.count, decisionCount)
    }
}
