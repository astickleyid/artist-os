import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class ApprovalFlowTests: XCTestCase {
    private func makeState() throws -> (AppState, CatalogStore) {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        return (state, store)
    }

    func testSectionApprovalPersistsDecisionAndCanonicalSource() throws {
        let (state, store) = try makeState()
        state.createSong(title: "Approval Test")
        let song = state.catalog.songs[0]
        let sectionID = song.sections[2].id

        let winner = Asset(
            id: UUID(), title: "Hook v2", originalFilename: "hook-v2.wav", role: .hook,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        let loser = Asset(
            id: UUID(), title: "Hook v1", originalFilename: "hook-v1.wav", role: .hook,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        state.catalog.assets.append(contentsOf: [winner, loser])
        try store.insert(asset: winner)
        try store.insert(asset: loser)
        state.setCanonicalSectionState(.needsDecision, sectionID: sectionID, songID: song.id)

        let eventCountBeforeApproval = state.catalog.events.count
        state.approveSectionDecision(
            sectionID: sectionID,
            songID: song.id,
            winner: winner.id,
            rejectedAssetIDs: [loser.id, winner.id, loser.id],
            reason: "  Better emotion in the hook.  "
        )

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == song.id })
        let updatedSection = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        XCTAssertEqual(updatedSection.assetID, winner.id)
        XCTAssertEqual(updatedSection.state, .locked)
        XCTAssertEqual(updatedSong.progress, 0.2, accuracy: 0.001)

        XCTAssertEqual(state.catalog.decisions.count, 2)
        let decision = try XCTUnwrap(state.catalog.decisions.last)
        XCTAssertEqual(decision.target, .hook)
        XCTAssertEqual(decision.action, .approved)
        XCTAssertEqual(decision.selectedAssetID, winner.id)
        XCTAssertEqual(decision.rejectedAssetIDs, [loser.id])
        XCTAssertEqual(decision.reason, "Better emotion in the hook.")

        let approvalEvents = Array(state.catalog.events.dropFirst(eventCountBeforeApproval))
        XCTAssertEqual(approvalEvents.map(\.operation), [.sourceSelected, .approved])
        XCTAssertEqual(decision.relatedEventIDs, approvalEvents.map(\.id))

        let composition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == song.id })
        let canonicalSection = try XCTUnwrap(composition.sections.first { $0.id == sectionID })
        let source = try XCTUnwrap(canonicalSection.selection(.sourceAsset))
        XCTAssertEqual(source.referenceID, winner.id)
        XCTAssertEqual(source.decisionID, decision.id)
        XCTAssertEqual(canonicalSection.state, .locked)

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.decisions.count, 2)
        XCTAssertEqual(reloaded.decisions.last?.id, decision.id)
        let persistedComposition = try XCTUnwrap(reloaded.masterCompositions.first { $0.songID == song.id })
        let persistedSection = try XCTUnwrap(persistedComposition.sections.first { $0.id == sectionID })
        XCTAssertEqual(persistedSection.selection(.sourceAsset)?.referenceID, winner.id)
        XCTAssertEqual(persistedSection.selection(.sourceAsset)?.decisionID, decision.id)
    }

    func testSectionApprovalPreservesIndependentCanonicalSelections() throws {
        let (state, store) = try makeState()
        state.createSong(title: "Layer Test")
        let song = state.catalog.songs[0]
        let sectionID = song.sections[0].id
        let sourceA = Asset(
            id: UUID(), title: "Take A", originalFilename: "a.wav", role: .leadVocal,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        let sourceB = Asset(
            id: UUID(), title: "Take B", originalFilename: "b.wav", role: .leadVocal,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        state.catalog.assets.append(contentsOf: [sourceA, sourceB])
        try store.insert(asset: sourceA)
        try store.insert(asset: sourceB)

        let processingID = UUID()
        var composition = MasterComposition.projected(from: song)
        let sectionIndex = try XCTUnwrap(composition.sections.firstIndex { $0.id == sectionID })
        composition.sections[sectionIndex].setSelection(MasterSelection(
            kind: .processingSnapshot,
            referenceID: processingID
        ))
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        state.approveSectionDecision(
            sectionID: sectionID,
            songID: song.id,
            winner: sourceB.id,
            rejectedAssetIDs: [sourceA.id]
        )

        let updated = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == song.id })
        let updatedSection = try XCTUnwrap(updated.sections.first { $0.id == sectionID })
        XCTAssertEqual(updatedSection.selection(.sourceAsset)?.referenceID, sourceB.id)
        XCTAssertEqual(updatedSection.selection(.processingSnapshot)?.referenceID, processingID)
    }

    func testSectionApprovalDerivesProgressAndRiskFromCanonicalComposition() throws {
        let (state, store) = try makeState()
        state.createSong(title: "Canonical Progress")
        let originalSong = state.catalog.songs[0]
        let approvedSectionID = originalSong.sections[0].id
        let unresolvedSectionID = originalSong.sections[1].id
        let winner = Asset(
            id: UUID(), title: "Approved Take", originalFilename: "approved.wav", role: .leadVocal,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: originalSong.id
        )
        state.catalog.assets.append(winner)
        try store.insert(asset: winner)

        var composition = MasterComposition.projected(from: originalSong)
        for index in composition.sections.indices {
            composition.sections[index].state = .locked
            composition.sections[index].confidence = 0.95
        }
        let approvedIndex = try XCTUnwrap(composition.sections.firstIndex { $0.id == approvedSectionID })
        let unresolvedIndex = try XCTUnwrap(composition.sections.firstIndex { $0.id == unresolvedSectionID })
        composition.sections[approvedIndex].state = .needsDecision
        composition.sections[unresolvedIndex].state = .needsDecision
        composition.updatedAt = Date()
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        var staleLegacySong = originalSong
        for index in staleLegacySong.sections.indices {
            staleLegacySong.sections[index].state = .locked
            staleLegacySong.sections[index].confidence = 1
        }
        staleLegacySong.progress = 1
        staleLegacySong.risk = "Master locked"
        staleLegacySong.updatedAt = composition.updatedAt
        state.catalog.songs[0] = staleLegacySong
        try store.upsert(song: staleLegacySong)

        state.approveSectionDecision(
            sectionID: approvedSectionID,
            songID: originalSong.id,
            winner: winner.id
        )

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == originalSong.id })
        XCTAssertEqual(updatedSong.progress, 0.8, accuracy: 0.001)
        XCTAssertEqual(updatedSong.risk, "\(composition.sections[unresolvedIndex].name) decision unresolved")
        XCTAssertNotEqual(updatedSong.risk, "Master locked")

        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == originalSong.id })
        XCTAssertEqual(updatedComposition.sections[approvedIndex].state, .locked)
        XCTAssertEqual(updatedComposition.sections[unresolvedIndex].state, .needsDecision)

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedSong = try XCTUnwrap(reloaded.songs.first { $0.id == originalSong.id })
        XCTAssertEqual(persistedSong.progress, 0.8, accuracy: 0.001)
        XCTAssertEqual(persistedSong.risk, "\(composition.sections[unresolvedIndex].name) decision unresolved")
    }

    func testMasterApprovalPersistsDecisionAndCanonicalOutput() throws {
        let (state, store) = try makeState()
        state.createSong(title: "Master Test")
        let song = state.catalog.songs[0]
        let winner = Asset(
            id: UUID(), title: "Mix 12", originalFilename: "mix12.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        let loser = Asset(
            id: UUID(), title: "Mix 11", originalFilename: "mix11.wav", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        state.catalog.assets.append(contentsOf: [winner, loser])
        try store.insert(asset: winner)
        try store.insert(asset: loser)

        state.approveMasterDecision(
            songID: song.id,
            assetID: winner.id,
            rejectedAssetIDs: [loser.id],
            reason: "More balanced low end."
        )

        XCTAssertEqual(state.catalog.songs[0].masterAssetID, winner.id)
        let decision = try XCTUnwrap(state.catalog.decisions.first)
        XCTAssertEqual(decision.target, .master)
        XCTAssertEqual(decision.selectedAssetID, winner.id)
        XCTAssertEqual(decision.rejectedAssetIDs, [loser.id])
        XCTAssertEqual(decision.reason, "More balanced low end.")
        XCTAssertEqual(state.catalog.masterCompositions.first?.outputAssetID, winner.id)
        XCTAssertEqual(state.catalog.events.last?.afterAssetID, winner.id)
        XCTAssertEqual(decision.relatedEventIDs, [state.catalog.events.last!.id])

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.songs[0].masterAssetID, winner.id)
        XCTAssertEqual(reloaded.decisions.first?.selectedAssetID, winner.id)
        XCTAssertEqual(reloaded.masterCompositions.first?.outputAssetID, winner.id)
    }

    func testRepeatedApprovalOfCurrentChoiceDoesNotDuplicateDecision() throws {
        let (state, store) = try makeState()
        state.createSong(title: "No Spam")
        let song = state.catalog.songs[0]
        let sectionID = song.sections[0].id
        let winner = Asset(
            id: UUID(), title: "One", originalFilename: "one.wav", role: .leadVocal,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        state.catalog.assets.append(winner)
        try store.insert(asset: winner)

        state.approveSectionDecision(sectionID: sectionID, songID: song.id, winner: winner.id)
        let decisionCount = state.catalog.decisions.count
        let eventCount = state.catalog.events.count
        state.approveSectionDecision(sectionID: sectionID, songID: song.id, winner: winner.id)

        XCTAssertEqual(state.catalog.decisions.count, decisionCount)
        XCTAssertEqual(state.catalog.events.count, eventCount)
    }
}
