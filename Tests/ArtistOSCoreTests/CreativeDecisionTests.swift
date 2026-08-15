import XCTest
@testable import ArtistOSCore

final class CreativeDecisionTests: XCTestCase {
    func testDecisionPreservesArtistIntentSeparatelyFromEventFacts() throws {
        let songID = UUID()
        let oldTake = UUID()
        let selectedTake = UUID()
        let eventID = UUID()

        let event = CreativeEvent(
            id: eventID,
            songID: songID,
            timestamp: Date(timeIntervalSince1970: 100),
            target: .hook,
            operation: .recordingUpdated,
            beforeAssetID: oldTake,
            afterAssetID: selectedTake,
            summary: "Hook recording changed from one asset to another.",
            confidence: 1
        )

        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: Date(timeIntervalSince1970: 101),
            target: .hook,
            action: .selected,
            selectedAssetID: selectedTake,
            rejectedAssetIDs: [oldTake],
            relatedEventIDs: [eventID],
            reason: "  Cleaner emotion in the second half.  "
        )

        XCTAssertEqual(event.operation, .recordingUpdated)
        XCTAssertEqual(decision.action, .selected)
        XCTAssertEqual(decision.selectedAssetID, selectedTake)
        XCTAssertEqual(decision.rejectedAssetIDs, [oldTake])
        XCTAssertEqual(decision.relatedEventIDs, [eventID])
        XCTAssertEqual(decision.reason, "Cleaner emotion in the second half.")
        XCTAssertEqual(decision.source, .artist)
    }

    func testOldCatalogJSONDecodesWithoutDecisionsField() throws {
        let json = """
        {
          "artistName": "STICK",
          "songs": [],
          "assets": [],
          "events": []
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(ArtistCatalog.self, from: json)
        XCTAssertEqual(catalog.artistName, "STICK")
        XCTAssertTrue(catalog.decisions.isEmpty)
    }

    func testBlankReasonBecomesNilSoNotesStayOptional() {
        let decision = CreativeDecision(
            id: UUID(),
            songID: UUID(),
            timestamp: Date(),
            target: .verse,
            action: .approved,
            selectedAssetID: nil,
            reason: "   "
        )

        XCTAssertNil(decision.reason)
    }
}
