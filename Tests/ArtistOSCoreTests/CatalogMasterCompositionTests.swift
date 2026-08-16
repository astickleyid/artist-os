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

    func testPersistedMasterCompositionWinsCatalogLookup() throws {
        let song = Song(
            id: UUID(),
            title: "Current",
            era: "E",
            status: .assembling,
            progress: 0,
            qualityScore: 0.5,
            risk: "",
            sections: [],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let persisted = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [],
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let catalog = ArtistCatalog(
            artistName: "T",
            songs: [song],
            assets: [],
            events: [],
            masterCompositions: [persisted]
        )

        XCTAssertEqual(catalog.masterComposition(for: song.id)?.id, persisted.id)
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
