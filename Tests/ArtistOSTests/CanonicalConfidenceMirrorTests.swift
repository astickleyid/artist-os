import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalConfidenceMirrorTests: XCTestCase {
    func testStateEditLeavesLegacyConfidenceUntouchedWhileCanonicalTruthPersists() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Confidence Mirror Retirement")

        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let sectionID = try XCTUnwrap(state.catalog.songs.first?.sections.first?.id)
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        let legacyIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })

        var composition = MasterComposition.projected(from: state.catalog.songs[songIndex])
        let canonicalIndex = try XCTUnwrap(composition.sections.firstIndex { $0.id == sectionID })
        composition.sections[canonicalIndex].confidence = 0.25
        composition.sections[canonicalIndex].state = .open
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        state.catalog.songs[songIndex].sections[legacyIndex].confidence = 0.95
        state.catalog.songs[songIndex].sections[legacyIndex].state = .open
        try store.upsert(song: state.catalog.songs[songIndex])

        state.setCanonicalSectionState(.needsDecision, sectionID: sectionID, songID: songID)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let updatedLegacy = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        let updatedCanonical = try XCTUnwrap(updatedComposition.sections.first { $0.id == sectionID })

        XCTAssertEqual(updatedCanonical.state, .needsDecision)
        XCTAssertEqual(updatedCanonical.confidence, 0.25, accuracy: 0.0001)
        XCTAssertEqual(updatedLegacy.state, .open)
        XCTAssertEqual(updatedLegacy.confidence, 0.95, accuracy: 0.0001)
        XCTAssertEqual(updatedSong.risk, "\(updatedCanonical.name) decision unresolved")

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedLegacy = try XCTUnwrap(
            reloaded.songs.first { $0.id == songID }?.sections.first { $0.id == sectionID }
        )
        let persistedCanonical = try XCTUnwrap(
            reloaded.masterCompositions.first { $0.songID == songID }?.sections.first { $0.id == sectionID }
        )
        XCTAssertEqual(persistedLegacy.state, .open)
        XCTAssertEqual(persistedLegacy.confidence, 0.95, accuracy: 0.0001)
        XCTAssertEqual(persistedCanonical.state, .needsDecision)
        XCTAssertEqual(persistedCanonical.confidence, 0.25, accuracy: 0.0001)
    }

    func testLockStateDoesNotRepairLegacyConfidenceMirror() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(store: store, seedIfNeeded: false, enableWatching: false)
        state.createSong(title: "Locked Confidence Mirror Retirement")

        let songID = try XCTUnwrap(state.catalog.songs.first?.id)
        let sectionID = try XCTUnwrap(state.catalog.songs.first?.sections.first?.id)
        let songIndex = try XCTUnwrap(state.catalog.songs.firstIndex { $0.id == songID })
        let legacyIndex = try XCTUnwrap(state.catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID })

        var composition = MasterComposition.projected(from: state.catalog.songs[songIndex])
        let canonicalIndex = try XCTUnwrap(composition.sections.firstIndex { $0.id == sectionID })
        composition.sections[canonicalIndex].confidence = 0.4
        composition.sections[canonicalIndex].state = .candidate
        state.catalog.setMasterComposition(composition)
        try store.upsert(masterComposition: composition)

        state.catalog.songs[songIndex].sections[legacyIndex].confidence = 1.0
        state.catalog.songs[songIndex].sections[legacyIndex].state = .candidate
        try store.upsert(song: state.catalog.songs[songIndex])

        state.setCanonicalSectionState(.locked, sectionID: sectionID, songID: songID)

        let updatedSong = try XCTUnwrap(state.catalog.songs.first { $0.id == songID })
        let updatedLegacy = try XCTUnwrap(updatedSong.sections.first { $0.id == sectionID })
        let updatedComposition = try XCTUnwrap(state.catalog.masterCompositions.first { $0.songID == songID })
        let updatedCanonical = try XCTUnwrap(updatedComposition.sections.first { $0.id == sectionID })

        XCTAssertEqual(updatedCanonical.state, .locked)
        XCTAssertEqual(updatedCanonical.confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(updatedLegacy.state, .candidate)
        XCTAssertEqual(updatedLegacy.confidence, 1.0, accuracy: 0.0001)

        let reloaded = store.loadCatalog(artistName: "T")
        let persistedLegacy = try XCTUnwrap(
            reloaded.songs.first { $0.id == songID }?.sections.first { $0.id == sectionID }
        )
        let persistedCanonical = try XCTUnwrap(
            reloaded.masterCompositions.first { $0.songID == songID }?.sections.first { $0.id == sectionID }
        )
        XCTAssertEqual(persistedLegacy.state, .candidate)
        XCTAssertEqual(persistedLegacy.confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(persistedCanonical.state, .locked)
        XCTAssertEqual(persistedCanonical.confidence, 0.9, accuracy: 0.0001)
    }
}
