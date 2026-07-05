import XCTest
@testable import ArtistOSCore

final class AssemblyTests: XCTestCase {

    func testUnifiedFoldersGroupByLabel() {
        let slices = [
            Assembly.Slice(assetId: "v1", assetTitle: "v1", version: "v1", sectionId: "a", label: "Hook", start: 16, end: 26, confidence: 0.7, bpm: 120),
            Assembly.Slice(assetId: "v2", assetTitle: "v2", version: "v2", sectionId: "b", label: "Hook", start: 15, end: 25, confidence: 0.7, bpm: 120),
            Assembly.Slice(assetId: "v1", assetTitle: "v1", version: "v1", sectionId: "c", label: "Verse", start: 6, end: 16, confidence: 0.6, bpm: 120),
            Assembly.Slice(assetId: "v3", assetTitle: "v3", version: "v3", sectionId: "d", label: "Bridge", start: 46, end: 54, confidence: 0.5, bpm: 120),
            Assembly.Slice(assetId: "v2", assetTitle: "v2", version: "v2", sectionId: "e", label: "Verse", start: 5, end: 15, confidence: 0.6, bpm: 120)
        ]
        let folders = Assembly.unifiedFolders(slices)
        XCTAssertEqual(folders.first(where: { $0.label == "Hook" })?.items.count, 2, "both hooks gathered")
        XCTAssertEqual(folders.first(where: { $0.label == "Verse" })?.items.count, 2, "both verses gathered")
        let labels = folders.map { $0.label }
        XCTAssertTrue(labels.firstIndex(of: "Verse")! < labels.firstIndex(of: "Hook")!, "canonical order")
        XCTAssertTrue(labels.firstIndex(of: "Hook")! < labels.firstIndex(of: "Bridge")!, "canonical order 2")
    }

    func testTotalDuration() {
        let recipe = [
            Assembly.Pick(slotId: "s1", label: "Verse", assetId: "v1", start: 6, end: 16),
            Assembly.Pick(slotId: "s2", label: "Hook", assetId: "v3", start: 16, end: 26)
        ]
        XCTAssertEqual(Assembly.totalDuration(recipe), 20)
    }

    func testSeamDetection() {
        let recipe = [
            Assembly.Pick(slotId: "s1", label: "Verse", assetId: "v1", start: 0, end: 10, bpm: 92, keyName: "A minor"),
            Assembly.Pick(slotId: "s2", label: "Hook", assetId: "v3", start: 0, end: 10, bpm: 120, keyName: "A minor"),
            Assembly.Pick(slotId: "s3", label: "Bridge", assetId: "v2", start: 0, end: 8, bpm: 120, keyName: "C major")
        ]
        let seams = Assembly.seamsFor(recipe)
        XCTAssertEqual(seams.count, 2, "two seams")
        XCTAssertTrue(seams[0].issues.contains { $0.type == .tempo }, "tempo seam")
        XCTAssertTrue(seams[1].issues.contains { $0.type == .key }, "key seam")
    }

    func testValidation() {
        XCTAssertFalse(Assembly.validateRecipe([]).ok, "empty invalid")
        let bad = Assembly.validateRecipe([Assembly.Pick(slotId: "s1", label: "Verse", assetId: nil, start: 0, end: 10)])
        XCTAssertFalse(bad.ok); XCTAssertTrue(bad.errors.first!.contains("no source"))
        let zero = Assembly.validateRecipe([Assembly.Pick(slotId: "s1", label: "Verse", assetId: "v1", start: 5, end: 5)])
        XCTAssertFalse(zero.ok); XCTAssertTrue(zero.errors.contains { $0.contains("zero length") })
        let good = Assembly.validateRecipe([Assembly.Pick(slotId: "s1", label: "Verse", assetId: "v1", start: 0, end: 10, bpm: 120, keyName: "A minor")])
        XCTAssertTrue(good.ok)
    }

    func testSeamsAreWarningsNotErrors() {
        let recipe = [
            Assembly.Pick(slotId: "s1", label: "Verse", assetId: "v1", start: 0, end: 10, bpm: 92),
            Assembly.Pick(slotId: "s2", label: "Hook", assetId: "v3", start: 0, end: 10, bpm: 120)
        ]
        let v = Assembly.validateRecipe(recipe)
        XCTAssertTrue(v.ok, "seams don't block render")
        XCTAssertGreaterThanOrEqual(v.warnings.count, 1, "seam surfaced as warning")
    }
}
