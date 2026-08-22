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

    func testRelativeSummaryReportsMeasuredTempoKeyAndDurationDifferences() {
        let assetA = makeAsset(bpm: 120, key: "F minor", duration: 93)
        let assetB = makeAsset(bpm: 122, key: "G minor", duration: 101)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "B 2 BPM faster · Key F minor → G minor · B 8s longer"
        )
    }

    func testRelativeSummarySuppressesDetectorNoise() {
        let assetA = makeAsset(bpm: 120.1, key: "F minor", duration: 93.2)
        let assetB = makeAsset(bpm: 120.4, key: "f MINOR", duration: 93.7)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "Same detected tempo · Same detected key · Same duration"
        )
    }

    func testRelativeSummaryUsesOnlyEvidenceAvailableOnBothSides() {
        let assetA = makeAsset(bpm: 126, key: nil, duration: nil)
        let assetB = makeAsset(bpm: 124, key: "A minor", duration: 150)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "B 2 BPM slower"
        )
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
