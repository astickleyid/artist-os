import XCTest
@testable import ArtistOSCore

final class ComparisonIntelligenceTests: XCTestCase {
    func testRecognizedSectionRoleFiltersOutUnrelatedAssets() {
        let hookA = makeAsset(role: .hook, title: "Hook A")
        let hookB = makeAsset(role: .hook, title: "Hook B")
        let fullMix = makeAsset(role: .fullMix, title: "Full Mix")
        let reference = makeAsset(role: .reference, title: "Reference")
        let section = MasterCompositionSection(name: "Hook", role: AssetRole.hook.rawValue)

        let candidates = ComparisonIntelligence.candidates(
            for: section,
            assets: [hookA, fullMix, hookB, reference]
        )

        XCTAssertEqual(candidates.map(\.id), [hookA.id, hookB.id])
    }

    func testCurrentCanonicalSourceSurvivesStaleImportedRoleMetadata() {
        let current = makeAsset(role: .leadVocal, title: "Current Hook")
        let alternate = makeAsset(role: .hook, title: "Hook Alt")
        let fullMix = makeAsset(role: .fullMix, title: "Full Mix")
        let section = MasterCompositionSection(
            name: "Hook",
            role: AssetRole.hook.rawValue,
            selections: [
                MasterSelection(kind: .sourceAsset, referenceID: current.id)
            ]
        )

        let candidates = ComparisonIntelligence.candidates(
            for: section,
            assets: [current, alternate, fullMix]
        )

        XCTAssertEqual(candidates.map(\.id), [current.id, alternate.id])
    }

    func testUnknownSectionRolePreservesExistingCandidateBehavior() {
        let vocal = makeAsset(role: .leadVocal, title: "Verse Vocal")
        let beat = makeAsset(role: .beat, title: "Beat")
        let section = MasterCompositionSection(name: "Verse 1", role: "Verse")

        let candidates = ComparisonIntelligence.candidates(
            for: section,
            assets: [vocal, beat]
        )

        XCTAssertEqual(candidates.map(\.id), [vocal.id, beat.id])
    }

    private func makeAsset(role: AssetRole, title: String) -> Asset {
        Asset(
            id: UUID(),
            title: title,
            originalFilename: "\(title).wav",
            role: role,
            createdAt: Date(),
            duration: nil,
            localURLBookmark: nil
        )
    }
}
