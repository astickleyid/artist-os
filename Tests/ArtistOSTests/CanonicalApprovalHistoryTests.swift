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
        XCTAssertEqual(updatedLegacySection.assetID, newWinner.id, "Legacy data remains a compatibility mirror until final retirement")

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedComposition = try XCTUnwrap(reloaded.masterCompositions.first { $0.songID == songID })
        let persistedSection = try XCTUnwrap(persistedComposition.sections.first { $0.id == sectionID })
        XCTAssertEqual(persistedSection.selection(.sourceAsset)?.referenceID, newWinner.id)
    }
}
