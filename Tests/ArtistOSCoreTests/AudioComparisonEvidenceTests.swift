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

    func testRelativeSummaryTreatsHalfDoubleTimeTempoAsSameFamily() {
        let assetA = makeAsset(bpm: 70, key: nil, duration: nil)
        let assetB = makeAsset(bpm: 140, key: nil, duration: nil)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "Same tempo family (half/double-time)"
        )
    }

    func testRelativeSummaryAllowsSmallDetectorDriftWithinHalfDoubleTimeFamily() {
        let assetA = makeAsset(bpm: 69.8, key: nil, duration: nil)
        let assetB = makeAsset(bpm: 140.2, key: nil, duration: nil)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "Same tempo family (half/double-time)"
        )
    }

    func testRelativeSummaryTreatsEnharmonicKeySpellingsAsEquivalent() {
        let assetA = makeAsset(bpm: nil, key: "C# minor", duration: nil)
        let assetB = makeAsset(bpm: nil, key: "D♭ minor", duration: nil)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "Same detected key"
        )
    }

    func testRelativeSummaryNormalizesMajorMinorAbbreviationsAndFlatSpellings() {
        let assetA = makeAsset(bpm: nil, key: "A# major", duration: nil)
        let assetB = makeAsset(bpm: nil, key: "Bb MAJ", duration: nil)

        XCTAssertEqual(
            AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB),
            "Same detected key"
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

    func testArrangementReviewSignalFlagsLargeRelativeLengthShift() {
        let assetA = makeAsset(bpm: nil, key: nil, duration: 100)
        let assetB = makeAsset(bpm: nil, key: nil, duration: 112)

        XCTAssertEqual(
            AudioComparisonEvidence.arrangementReviewSignal(between: assetA, and: assetB),
            "Arrangement check · B is 12% longer"
        )
    }

    func testArrangementReviewSignalHandlesShorterCandidate() {
        let assetA = makeAsset(bpm: nil, key: nil, duration: 100)
        let assetB = makeAsset(bpm: nil, key: nil, duration: 90)

        XCTAssertEqual(
            AudioComparisonEvidence.arrangementReviewSignal(between: assetA, and: assetB),
            "Arrangement check · B is 10% shorter"
        )
    }

    func testArrangementReviewSignalRequiresAbsoluteAndRelativeDifference() {
        XCTAssertNil(
            AudioComparisonEvidence.arrangementReviewSignal(
                between: makeAsset(bpm: nil, key: nil, duration: 100),
                and: makeAsset(bpm: nil, key: nil, duration: 106)
            )
        )
        XCTAssertNil(
            AudioComparisonEvidence.arrangementReviewSignal(
                between: makeAsset(bpm: nil, key: nil, duration: 300),
                and: makeAsset(bpm: nil, key: nil, duration: 310)
            )
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
