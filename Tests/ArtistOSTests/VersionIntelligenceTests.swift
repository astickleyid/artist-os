import XCTest
@testable import ArtistOS

final class VersionIntelligenceTests: XCTestCase {
    private func pv(_ n: String) -> VersionIntelligence.Parsed { VersionIntelligence.parse(n) }

    func testSharedVectors() { // MUST mirror tests/web/core.test.js
        XCTAssertEqual(pv("baddest times v1.m4a"),
            .init(canonical: "baddest times", label: "v1", order: 1))
        XCTAssertEqual(pv("baddest times v2.m4a").order, 2)
        XCTAssertEqual(pv("baddest times(3).m4a"),
            .init(canonical: "baddest times", label: "3", order: 3))
        XCTAssertEqual(pv("baddest times final.m4a").canonical, "baddest times")
        XCTAssertEqual(pv("baddest times final.m4a").label, "final")
        XCTAssertEqual(pv("baddest times FINAL final.wav").canonical, "baddest times")
        XCTAssertEqual(pv("baddest times mix2.wav").order, 2)
        XCTAssertEqual(pv("candidcamera(apple master)_1.m4a").canonical, "candidcamera")
        XCTAssertEqual(pv("candidcamera(apple master)_1.m4a").order, 1)
        XCTAssertEqual(pv("golden state - master 3.wav").canonical, "golden state")
        XCTAssertEqual(pv("golden state - master 3.wav").order, 3)
        XCTAssertEqual(pv("0412.m4a").canonical, "0412")
        XCTAssertEqual(pv("v2.wav").canonical, "v2")
        XCTAssertEqual(pv("golden hook take2.m4a").canonical, "golden hook")
    }

    func testStackOrderingAndMasterGating() {
        func asset(_ role: AssetRole, _ v: String?, _ o: Int?) -> Asset {
            Asset(id: UUID(), title: "t", originalFilename: "f", role: role,
                  createdAt: Date(), duration: nil, localURLBookmark: nil,
                  version: v, vOrder: o)
        }
        let stack = VersionIntelligence.versionStack(
            [asset(.fullMix, "v1", 1), asset(.fullMix, "final", nil), asset(.fullMix, "v3", 3)]
        )
        XCTAssertEqual(stack.first?.version, "v3")
        // hook + beat "versions" are not a master stack
        XCTAssertTrue(VersionIntelligence.masterStack(
            [asset(.hook, "take1", 1), asset(.beat, "v1", 1)]).isEmpty)
        XCTAssertEqual(VersionIntelligence.masterStack(
            [asset(.fullMix, "v1", 1), asset(.fullMix, "v2", 2)]).count, 2)
    }
}
