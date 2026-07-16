import XCTest
@testable import ArtistOSCore

final class CompTests: XCTestCase {

    func testNewCompIsSingleDefault() {
        let comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        XCTAssertEqual(comp.segments.count, 1)
        XCTAssertEqual(Comp.sourceAt(comp, 50), "v1")
    }

    func testSwipeSplitsIntoThree() {
        var comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 30, to: 60)
        XCTAssertEqual(comp.segments.map { $0.sourceId }, ["v1", "v2", "v1"])
        XCTAssertEqual(Comp.sourceAt(comp, 45), "v2")
        XCTAssertEqual(Comp.sourceAt(comp, 20), "v1")
    }

    func testOverlappingSwipeLastWins() {
        var comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 30, to: 60)
        comp = Comp.applySwipe(comp, sourceId: "v3", from: 50, to: 80)
        XCTAssertEqual(Comp.sourceAt(comp, 55), "v3", "v3 overrides where swiped")
        XCTAssertEqual(Comp.sourceAt(comp, 40), "v2", "earlier v2 survives outside overlap")
        XCTAssertEqual(Comp.sourceAt(comp, 90), "v1")
    }

    func testAdjacentSameSourceMerges() {
        var comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 0, to: 50)
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 50, to: 100)
        XCTAssertEqual(comp.segments.count, 1, "adjacent identical sources merge")
        XCTAssertEqual(comp.segments.first?.sourceId, "v2")
    }

    func testBoundaries() {
        var comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 30, to: 60)
        XCTAssertEqual(Comp.boundaries(comp), [30, 60])
    }

    func testCoverageAndSourcesUsed() {
        var comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 30, to: 60)
        let cov = Comp.coverage(comp)
        XCTAssertEqual(cov["v1"], 70)
        XCTAssertEqual(cov["v2"], 30)
        XCTAssertEqual(Comp.sourcesUsed(comp), 2)
    }

    func testFullRangeSwipeReplacesAll() {
        var comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        comp = Comp.applySwipe(comp, sourceId: "v2", from: 30, to: 60)
        comp = Comp.applySwipe(comp, sourceId: "v3", from: 0, to: 100)
        XCTAssertEqual(comp.segments.count, 1)
        XCTAssertEqual(comp.segments.first?.sourceId, "v3")
    }

    func testZeroLengthNoOpAndClamp() {
        let comp = Comp.makeComp(duration: 100, defaultSourceId: "v1")
        let z = Comp.applySwipe(comp, sourceId: "v2", from: 50, to: 50)
        XCTAssertEqual(z.segments.count, 1, "zero-length swipe is a no-op")
        let c = Comp.applySwipe(comp, sourceId: "v2", from: -20, to: 200)
        XCTAssertEqual(c.segments.first?.start, 0)
        XCTAssertEqual(c.segments.first?.end, 100)
    }

    func testLoudnessGains() {
        let g = Comp.loudnessGains(["v1": 0.1, "v2": 0.2, "v3": 0.05])
        XCTAssertEqual(g["v2"], 1, "loudest = gain 1")
        XCTAssertEqual(g["v1"]!, 2, accuracy: 1e-9, "quieter boosted x2")
        XCTAssertEqual(g["v3"]!, 4, accuracy: 1e-9, "much quieter capped at x4")
    }
}
