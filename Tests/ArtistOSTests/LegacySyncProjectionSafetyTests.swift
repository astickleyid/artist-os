import XCTest
import ArtistOSCore
@testable import ArtistOS

final class LegacySyncProjectionSafetyTests: XCTestCase {
    func testNewSongSyncNoLongerCarriesLegacySourceOrMasterProjectionTruth() throws {
        let songID = UUID()
        let sectionID = UUID()
        let sourceAssetID = UUID()
        let masterAssetID = UUID()
        let section = MasterSection(
            id: sectionID,
            name: "Hook",
            role: "Hook",
            assetID: sourceAssetID,
            state: .candidate,
            confidence: 0.81,
            note: "Keep this take for the current hook."
        )
        let original = Song(
            id: songID,
            title: "Legacy Sync Projection",
            era: "Imported",
            status: .assembling,
            progress: 0.25,
            qualityScore: 0.5,
            risk: "",
            sections: [section],
            masterAssetID: masterAssetID,
            updatedAt: Date(timeIntervalSince1970: 456)
        )

        let payload = SyncLogic.songPayload(original)
        XCTAssertNil(payload["masterAssetId"])
        let encodedSections = try XCTUnwrap(payload["sections"] as? [SyncLogic.JSONDict])
        XCTAssertNil(try XCTUnwrap(encodedSections.first)["assetId"])

        let merged = try XCTUnwrap(
            SyncLogic.mergedSong(
                payload: payload,
                updatedAt: original.updatedAt,
                existing: nil
            )
        )
        let catalog = ArtistCatalog(
            artistName: "T",
            songs: [merged],
            assets: [],
            events: [],
            masterCompositions: []
        )
        let projected = try XCTUnwrap(catalog.masterComposition(for: songID))
        let projectedSection = try XCTUnwrap(projected.sections.first)

        XCTAssertNil(projected.outputAssetID)
        XCTAssertEqual(projected.updatedAt, original.updatedAt)
        XCTAssertEqual(projectedSection.id, sectionID)
        XCTAssertEqual(projectedSection.name, section.name)
        XCTAssertEqual(projectedSection.role, section.role)
        XCTAssertNil(projectedSection.selection(.sourceAsset)?.referenceID)
        XCTAssertEqual(projectedSection.state, section.state)
        XCTAssertEqual(projectedSection.confidence, section.confidence, accuracy: 0.0001)
        XCTAssertEqual(projectedSection.note, section.note)
    }
}
