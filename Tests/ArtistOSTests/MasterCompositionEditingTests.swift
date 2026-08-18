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
