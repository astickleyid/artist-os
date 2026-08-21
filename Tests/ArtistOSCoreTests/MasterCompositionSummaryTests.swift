import XCTest
@testable import ArtistOSCore

final class MasterCompositionSummaryTests: XCTestCase {
    func testCanonicalSummaryUsesCompositionState() {
        let composition = MasterComposition(
            songID: UUID(),
            sections: [
                MasterCompositionSection(name: "Intro", role: "Intro", state: .locked),
                MasterCompositionSection(name: "Hook", role: "Hook", state: .needsDecision),
                MasterCompositionSection(name: "Verse", role: "Verse", state: .open)
            ]
        )

        XCTAssertEqual(composition.lockedProgress, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(composition.riskSummary, "Hook decision unresolved")
    }

    func testCanonicalSummaryReportsLockedOnlyWhenEverySectionIsLocked() {
        let locked = MasterComposition(
            songID: UUID(),
            sections: [
                MasterCompositionSection(name: "Verse", role: "Verse", state: .locked),
                MasterCompositionSection(name: "Hook", role: "Hook", state: .locked)
            ]
        )
        let assembling = MasterComposition(
            songID: UUID(),
            sections: [
                MasterCompositionSection(name: "Verse", role: "Verse", state: .locked),
                MasterCompositionSection(name: "Hook", role: "Hook", state: .open)
            ]
        )

        XCTAssertEqual(locked.lockedProgress, 1)
        XCTAssertEqual(locked.riskSummary, "Master locked")
        XCTAssertEqual(assembling.lockedProgress, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(assembling.riskSummary, "In assembly")
    }

    func testEmptyCompositionSummaryIsSafe() {
        let composition = MasterComposition(songID: UUID(), sections: [])

        XCTAssertEqual(composition.lockedProgress, 0)
        XCTAssertEqual(composition.riskSummary, "In assembly")
    }
}
