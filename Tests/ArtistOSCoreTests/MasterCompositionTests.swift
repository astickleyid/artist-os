import XCTest
@testable import ArtistOSCore

final class MasterCompositionTests: XCTestCase {
    func testProcessingCanChangeWithoutReplacingRecording() {
        let recordingID = UUID()
        let processingA = UUID()
        let processingB = UUID()
        let decisionID = UUID()

        var section = MasterCompositionSection(
            name: "Verse 1",
            role: "Lead vocal",
            selections: [
                MasterSelection(kind: .sourceAsset, referenceID: recordingID),
                MasterSelection(kind: .processingSnapshot, referenceID: processingA)
            ],
            state: .candidate
        )

        section.setSelection(MasterSelection(
            kind: .processingSnapshot,
            referenceID: processingB,
            decisionID: decisionID
        ))

        XCTAssertEqual(section.selection(.sourceAsset)?.referenceID, recordingID)
        XCTAssertEqual(section.selection(.processingSnapshot)?.referenceID, processingB)
        XCTAssertEqual(section.selection(.processingSnapshot)?.decisionID, decisionID)
        XCTAssertFalse(section.selections.contains { $0.referenceID == processingA })
    }

    func testEachSelectionKindHasOnlyOneCurrentBinding() {
        let first = UUID()
        let second = UUID()
        var section = MasterCompositionSection(name: "Hook", role: "Lead")

        section.setSelection(MasterSelection(kind: .sourceAsset, referenceID: first))
        section.setSelection(MasterSelection(kind: .sourceAsset, referenceID: second))

        XCTAssertEqual(section.selections.filter { $0.kind == .sourceAsset }.count, 1)
        XCTAssertEqual(section.selection(.sourceAsset)?.referenceID, second)
    }

    func testLegacySongProjectionPreservesCurrentTruth() {
        let assetID = UUID()
        let masterID = UUID()
        let sectionID = UUID()
        let updated = Date(timeIntervalSince1970: 12345)
        let song = Song(
            id: UUID(),
            title: "Golden State",
            era: "Golden State",
            status: .assembling,
            progress: 0.7,
            qualityScore: 0.8,
            risk: "Hook unresolved",
            sections: [
                MasterSection(
                    id: sectionID,
                    name: "Hook",
                    role: "Melody",
                    assetID: assetID,
                    state: .needsDecision,
                    confidence: 0.72,
                    note: "Compare A/B"
                )
            ],
            masterAssetID: masterID,
            updatedAt: updated
        )

        let composition = MasterComposition.projected(from: song)

        XCTAssertEqual(composition.songID, song.id)
        XCTAssertEqual(composition.outputAssetID, masterID)
        XCTAssertEqual(composition.updatedAt, updated)
        XCTAssertEqual(composition.sections.count, 1)
        XCTAssertEqual(composition.sections[0].id, sectionID)
        XCTAssertEqual(composition.sections[0].selection(.sourceAsset)?.referenceID, assetID)
        XCTAssertEqual(composition.sections[0].state, .needsDecision)
        XCTAssertEqual(composition.unresolvedSectionIDs, [sectionID])
        XCTAssertFalse(composition.isDecisionComplete)
    }

    func testCompositionCanRepresentCompRecipeAlongsideSourceAndProcessing() {
        let source = UUID()
        let processing = UUID()
        let comp = UUID()
        let section = MasterCompositionSection(
            name: "Hook",
            role: "Melody",
            selections: [
                MasterSelection(kind: .sourceAsset, referenceID: source),
                MasterSelection(kind: .processingSnapshot, referenceID: processing),
                MasterSelection(kind: .compRecipe, referenceID: comp)
            ],
            state: .locked,
            confidence: 0.95
        )
        let composition = MasterComposition(songID: UUID(), sections: [section])

        XCTAssertEqual(composition.sections[0].selection(.sourceAsset)?.referenceID, source)
        XCTAssertEqual(composition.sections[0].selection(.processingSnapshot)?.referenceID, processing)
        XCTAssertEqual(composition.sections[0].selection(.compRecipe)?.referenceID, comp)
        XCTAssertTrue(composition.isDecisionComplete)
    }
}
