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

    func testRankedCandidatesKeepCanonicalSourceFirstAndNewestChallengerNext() {
        let now = Date()
        let current = makeAsset(
            role: .hook,
            title: "Hook Current",
            modifiedAt: now.addingTimeInterval(-300),
            vOrder: 2
        )
        let older = makeAsset(
            role: .hook,
            title: "Hook Old",
            modifiedAt: now.addingTimeInterval(-200),
            vOrder: 1
        )
        let newest = makeAsset(
            role: .hook,
            title: "Hook New",
            modifiedAt: now,
            vOrder: 3
        )
        let section = MasterCompositionSection(
            name: "Hook",
            role: AssetRole.hook.rawValue,
            selections: [
                MasterSelection(kind: .sourceAsset, referenceID: current.id)
            ]
        )

        let ranked = ComparisonIntelligence.rankedCandidates(
            for: section,
            assets: [older, current, newest]
        )

        XCTAssertEqual(ranked.map(\.id), [current.id, newest.id, older.id])
    }

    func testRankedCandidatesUseVersionRecencyWhenThereIsNoCurrentSource() {
        let now = Date()
        let v1 = makeAsset(
            role: .bridge,
            title: "Bridge v1",
            modifiedAt: now,
            vOrder: 1
        )
        let v3 = makeAsset(
            role: .bridge,
            title: "Bridge v3",
            modifiedAt: now.addingTimeInterval(-100),
            vOrder: 3
        )
        let v2 = makeAsset(
            role: .bridge,
            title: "Bridge v2",
            modifiedAt: now.addingTimeInterval(100),
            vOrder: 2
        )
        let section = MasterCompositionSection(name: "Bridge", role: AssetRole.bridge.rawValue)

        let ranked = ComparisonIntelligence.rankedCandidates(
            for: section,
            assets: [v1, v2, v3]
        )

        XCTAssertEqual(ranked.map(\.id), [v3.id, v2.id, v1.id])
    }

    func testSurfacingReasonIdentifiesCanonicalSourceAndHighestVersionChallenger() {
        let current = makeAsset(role: .hook, title: "Hook Current", vOrder: 2)
        let newest = makeAsset(role: .hook, title: "Hook v4", vOrder: 4)
        let older = makeAsset(role: .hook, title: "Hook v3", vOrder: 3)
        let section = MasterCompositionSection(
            name: "Hook",
            role: AssetRole.hook.rawValue,
            selections: [MasterSelection(kind: .sourceAsset, referenceID: current.id)]
        )
        let assets = [older, current, newest]

        XCTAssertEqual(
            ComparisonIntelligence.surfacingReason(for: current, section: section, assets: assets),
            .currentCanonicalSource
        )
        XCTAssertEqual(
            ComparisonIntelligence.surfacingReason(for: newest, section: section, assets: assets),
            .highestVersionLabel(4)
        )
        XCTAssertEqual(
            ComparisonIntelligence.surfacingReason(for: older, section: section, assets: assets),
            .alternative
        )
    }

    func testSurfacingReasonFallsBackToModificationRecencyWithoutVersionDifference() {
        let now = Date()
        let current = makeAsset(role: .leadVocal, title: "Current", modifiedAt: now.addingTimeInterval(-300))
        let newest = makeAsset(role: .leadVocal, title: "New Take", modifiedAt: now)
        let older = makeAsset(role: .leadVocal, title: "Old Take", modifiedAt: now.addingTimeInterval(-100))
        let section = MasterCompositionSection(
            name: "Lead Vocal",
            role: AssetRole.leadVocal.rawValue,
            selections: [MasterSelection(kind: .sourceAsset, referenceID: current.id)]
        )
        let assets = [older, current, newest]

        XCTAssertEqual(
            ComparisonIntelligence.surfacingReason(for: newest, section: section, assets: assets),
            .mostRecentlyModified
        )
    }

    private func makeAsset(
        role: AssetRole,
        title: String,
        modifiedAt: Date? = nil,
        vOrder: Int? = nil
    ) -> Asset {
        Asset(
            id: UUID(),
            title: title,
            originalFilename: "\(title).wav",
            role: role,
            createdAt: modifiedAt ?? Date(),
            duration: nil,
            localURLBookmark: nil,
            fileModifiedAt: modifiedAt,
            version: vOrder.map { "v\($0)" },
            vOrder: vOrder
        )
    }
}
