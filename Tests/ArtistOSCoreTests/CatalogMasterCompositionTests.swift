import XCTest
@testable import ArtistOSCore

final class CatalogMasterCompositionTests: XCTestCase {
    func testOldCatalogJSONDecodesWithoutMasterCompositionsField() throws {
        let songID = UUID()
        let json = """
        {
          "artistName": "T",
          "songs": [{
            "id": "\(songID.uuidString)",
            "title": "Legacy",
            "era": "Imported",
            "status": "In Assembly",
            "progress": 0,
            "qualityScore": 0.5,
            "risk": "",
            "sections": [],
            "updatedAt": 0
          }],
          "assets": [],
          "events": [],
          "decisions": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let catalog = try decoder.decode(ArtistCatalog.self, from: Data(json.utf8))

        XCTAssertTrue(catalog.masterCompositions.isEmpty)
        let projected = try XCTUnwrap(catalog.masterComposition(for: songID))
        XCTAssertEqual(projected.id, songID)
        XCTAssertEqual(projected.songID, songID)
    }

    func testLegacySongProjectsCompleteCanonicalMasterState() throws {
        let songID = UUID()
        let sectionID = UUID()
        let sourceAssetID = UUID()
        let masterAssetID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 123)
        let legacySection = MasterSection(
            id: sectionID,
            name: "Hook",
            role: "Hook",
            assetID: sourceAssetID,
            state: .candidate,
            confidence: 0.73,
            note: "Keep the first vocal take."
        )
        let song = Song(
            id: songID,
            title: "Legacy Projection",
            era: "Imported",
            status: .assembling,
            progress: 0.2,
            qualityScore: 0.5,
            risk: "",
            sections: [legacySection],
            masterAssetID: masterAssetID,
            updatedAt: updatedAt
        )
        let catalog = ArtistCatalog(
            artistName: "T",
            songs: [song],
            assets: [],
            events: [],
            masterCompositions: []
        )

        let projected = try XCTUnwrap(catalog.masterComposition(for: songID))
        let section = try XCTUnwrap(projected.sections.first)

        XCTAssertEqual(projected.songID, songID)
        XCTAssertEqual(projected.outputAssetID, masterAssetID)
        XCTAssertEqual(projected.updatedAt, updatedAt)
        XCTAssertEqual(section.id, sectionID)
        XCTAssertEqual(section.name, legacySection.name)
        XCTAssertEqual(section.role, legacySection.role)
        XCTAssertEqual(section.selection(.sourceAsset)?.referenceID, sourceAssetID)
        XCTAssertEqual(section.state, legacySection.state)
        XCTAssertEqual(section.confidence, legacySection.confidence, accuracy: 0.0001)
        XCTAssertEqual(section.note, legacySection.note)
    }

    func testPersistedMasterCompositionWinsCatalogLookup() throws {
        let legacyMasterID = UUID()
        let canonicalMasterID = UUID()
        let song = Song(
            id: UUID(),
            title: "Current",
            era: "E",
            status: .assembling,
            progress: 0,
            qualityScore: 0.5,
            risk: "",
            sections: [],
            masterAssetID: legacyMasterID,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let persisted = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [],
            outputAssetID: canonicalMasterID,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let catalog = ArtistCatalog(
            artistName: "T",
            songs: [song],
            assets: [],
            events: [],
            masterCompositions: [persisted]
        )

        let resolved = try XCTUnwrap(catalog.masterComposition(for: song.id))
        XCTAssertEqual(resolved.id, persisted.id)
        XCTAssertEqual(resolved.outputAssetID, canonicalMasterID)
        XCTAssertNotEqual(resolved.outputAssetID, legacyMasterID)
    }

    func testCatalogNormalizesDuplicateCanonicalTruthToNewestComposition() {
        let songID = UUID()
        let older = MasterComposition(
            id: UUID(),
            songID: songID,
            sections: [],
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = MasterComposition(
            id: UUID(),
            songID: songID,
            sections: [],
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let catalog = ArtistCatalog(
            artistName: "T",
            songs: [],
            assets: [],
            events: [],
            masterCompositions: [newer, older]
        )

        XCTAssertEqual(catalog.masterCompositions.count, 1)
        XCTAssertEqual(catalog.masterCompositions[0].id, newer.id)
    }

    func testSetMasterCompositionReplacesExistingTruthForSong() {
        let songID = UUID()
        let first = MasterComposition(id: UUID(), songID: songID, sections: [])
        let second = MasterComposition(id: UUID(), songID: songID, sections: [])
        var catalog = ArtistCatalog(
            artistName: "T",
            songs: [],
            assets: [],
            events: [],
            masterCompositions: [first]
        )

        catalog.setMasterComposition(second)

        XCTAssertEqual(catalog.masterCompositions.count, 1)
        XCTAssertEqual(catalog.masterComposition(for: songID)?.id, second.id)
    }
}
