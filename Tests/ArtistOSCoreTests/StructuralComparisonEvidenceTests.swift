import XCTest
@testable import ArtistOSCore

final class StructuralComparisonEvidenceTests: XCTestCase {
    func testReportsDetectedSectionAndRepetitionGroupDifferences() {
        let a = Segmentation.Result(
            sections: [
                section(0, 0, 30),
                section(1, 30, 60),
                section(2, 60, 90)
            ],
            clusterCount: 2,
            frameCount: 180
        )
        let b = Segmentation.Result(
            sections: [
                section(0, 0, 20),
                section(1, 20, 45),
                section(2, 45, 70),
                section(3, 70, 90)
            ],
            clusterCount: 3,
            frameCount: 180
        )

        XCTAssertEqual(
            StructuralComparisonEvidence.summary(between: a, and: b),
            "Detected sections 3 → 4 · repetition groups 2 → 3"
        )
    }

    func testReportsSimilarNormalizedBoundaryPatternAcrossDifferentDurations() {
        let a = Segmentation.Result(
            sections: [
                section(0, 0, 30),
                section(1, 30, 60),
                section(2, 60, 90)
            ],
            clusterCount: 2,
            frameCount: 180
        )
        let b = Segmentation.Result(
            sections: [
                section(0, 0, 40),
                section(1, 40, 80),
                section(2, 80, 120)
            ],
            clusterCount: 2,
            frameCount: 240
        )

        XCTAssertEqual(
            StructuralComparisonEvidence.summary(between: a, and: b),
            "similar boundary pattern"
        )
    }

    func testReportsMaterialNormalizedBoundaryShift() {
        let a = Segmentation.Result(
            sections: [
                section(0, 0, 30),
                section(1, 30, 60),
                section(2, 60, 100)
            ],
            clusterCount: 2,
            frameCount: 200
        )
        let b = Segmentation.Result(
            sections: [
                section(0, 0, 18),
                section(1, 18, 72),
                section(2, 72, 100)
            ],
            clusterCount: 2,
            frameCount: 200
        )

        XCTAssertEqual(
            StructuralComparisonEvidence.summary(between: a, and: b),
            "boundary pattern shifts up to 12% of runtime"
        )
    }

    func testSingleUndifferentiatedSectionsDoNotCreateStructuralClaim() {
        let a = Segmentation.Result(
            sections: [section(0, 0, 90)],
            clusterCount: 1,
            frameCount: 180
        )
        let b = Segmentation.Result(
            sections: [section(0, 0, 92)],
            clusterCount: 1,
            frameCount: 184
        )

        XCTAssertNil(StructuralComparisonEvidence.summary(between: a, and: b))
    }

    private func section(_ index: Int, _ start: Double, _ end: Double) -> Segmentation.Section {
        Segmentation.Section(
            index: index,
            start: start,
            end: end,
            label: "Section",
            confidence: 0.5,
            cluster: index
        )
    }
}
