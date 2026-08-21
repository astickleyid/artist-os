import XCTest
@testable import ArtistOSCore

final class AudioComparisonEvidenceTests: XCTestCase {
    func testSummaryIncludesDetectedTempoKeyAndDurationWithoutJudgment() {
        let asset = makeAsset(bpm: 119.96, key: "F minor", duration: 93.4)

        XCTAssertEqual(
            AudioComparisonEvidence.summary(for: asset),
            "120 BPM · F minor · 1:33"
        )
    }

    func testSummaryKeepsUsefulPartialEvidence() {
        let asset = makeAsset(bpm: 126.5, key: nil, duration: nil)

        XCTAssertEqual(AudioComparisonEvidence.summary(for: asset), "126.5 BPM")
    }

    func testSummaryIgnoresInvalidOrMissingEvidence() {
        let asset = makeAsset(bpm: -1, key: "   ", duration: 0)

        XCTAssertNil(AudioComparisonEvidence.summary(for: asset))
    }

    private func makeAsset(
        bpm: Double?,
        key: String?,
        duration: TimeInterval?
    ) -> Asset {
        Asset(
            id: UUID(),
            title: "Candidate",
            originalFilename: "candidate.wav",
            role: .hook,
            createdAt: Date(),
            duration: duration,
            localURLBookmark: nil,
            bpm: bpm,
            musicalKey: key
        )
    }
}
