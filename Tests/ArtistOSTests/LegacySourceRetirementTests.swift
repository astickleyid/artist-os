import XCTest
import ArtistOSCore
@testable import ArtistOS

final class LegacySourceRetirementTests: XCTestCase {
    func testPersistedCanonicalCompositionSurvivesClearedLegacySourceMirrors() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Retirement Proof")

        let sectionID = song.sections[0].id
        let canonicalSourceID = UUID()
        let processingID = UUID()
        let outputID = UUID()
        let decisionID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_802_468_000.25)

        // Start from a compatibility-shaped Song so this test models an actual
        // migrated catalog rather than a brand-new canonical-only fixture.
        song.sections[0].assetID = UUID()
        song.masterAssetID = UUID()
        try store.upsert(song: song)

        let composition = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [
                MasterCompositionSection(
                    id: sectionID,
                    name: song.sections[0].name,
                    role: song.sections[0].role,
                    selections: [
                        MasterSelection(
                            kind: .sourceAsset,
                            referenceID: canonicalSourceID,
                            decisionID: decisionID,
                            selectedAt: updatedAt
                        ),
                        MasterSelection(
                            kind: .processingSnapshot,
                            referenceID: processingID,
                            selectedAt: updatedAt
                        )
                    ],
                    state: .locked,
                    confidence: 0.93,
                    note: "Canonical state must outlive compatibility mirrors"
                )
            ],
            outputAssetID: outputID,
            updatedAt: updatedAt
        )
        try store.upsert(masterComposition: composition)

        // Simulate the final migration step: legacy source/master mirrors no
        // longer carry current creative truth, while canonical persistence stays.
        song.sections.indices.forEach { song.sections[$0].assetID = nil }
        song.masterAssetID = nil
        song.updatedAt = updatedAt.addingTimeInterval(1)
        try store.upsert(song: song)

        let reloaded = store.loadCatalog(artistName: "T")
        let reloadedSong = try XCTUnwrap(reloaded.songs.first { $0.id == song.id })
        XCTAssertTrue(reloadedSong.sections.allSatisfy { $0.assetID == nil })
        XCTAssertNil(reloadedSong.masterAssetID)

        let resolved = try XCTUnwrap(reloaded.masterComposition(for: song.id))
        XCTAssertEqual(resolved.id, composition.id)
        XCTAssertEqual(resolved.outputAssetID, outputID)
        XCTAssertEqual(resolved.sections.count, 1)

        let section = try XCTUnwrap(resolved.sections.first { $0.id == sectionID })
        XCTAssertEqual(section.selection(.sourceAsset)?.referenceID, canonicalSourceID)
        XCTAssertEqual(section.selection(.sourceAsset)?.decisionID, decisionID)
        XCTAssertEqual(section.selection(.processingSnapshot)?.referenceID, processingID)
        XCTAssertEqual(section.state, .locked)
        XCTAssertEqual(section.confidence, 0.93, accuracy: 0.0001)
        XCTAssertEqual(section.note, "Canonical state must outlive compatibility mirrors")
    }
}
