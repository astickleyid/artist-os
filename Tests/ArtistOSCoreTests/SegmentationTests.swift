import XCTest
@testable import ArtistOSCore

final class SegmentationTests: XCTestCase {
    let SR: Double = 8000

    // Build a synthetic song with KNOWN structure by giving each section a
    // distinct chord (chroma signature). Recurring sections reuse the chord.
    // Structure: Intro | Verse | HOOK | Verse | HOOK | Bridge | HOOK
    private func chord(_ freqs: [Double], _ seconds: Double) -> [Float] {
        let n = Int(SR * seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for f in freqs { s += sin(2 * Double.pi * f * Double(i) / SR) }
            out[i] = Float(s / Double(freqs.count) * 0.8)
        }
        return out
    }

    private func makeSong() -> [Float] {
        let cIntro  = chord([131, 165, 196], 6)
        let cVerse  = chord([147, 175, 220], 10)
        let cHook   = chord([196, 247, 294], 10)
        let cBridge = chord([175, 208, 262], 8)
        var song: [Float] = []
        song += cIntro; song += cVerse; song += cHook
        song += cVerse; song += cHook; song += cBridge; song += cHook
        return song
    }

    func testFindsKnownStructure() {
        var opts = Segmentation.Options()
        opts.hopSeconds = 0.5
        opts.minSectionSeconds = 4
        let result = Segmentation.segment(makeSong(), sampleRate: SR, options: opts)

        // plausible number of sections (5..9 given detection tolerance)
        XCTAssertTrue(result.sections.count >= 5 && result.sections.count <= 9,
                      "finds a plausible number of sections (got \(result.sections.count))")

        // the recurring hook chord appears 3x -> its cluster should repeat
        var counts: [Int: Int] = [:]
        for s in result.sections { counts[s.cluster, default: 0] += 1 }
        let maxRepeat = counts.values.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxRepeat, 2, "recurring section detected as repeating")

        // proposed as Hook across its repeats
        let hooks = result.sections.filter { $0.label == "Hook" }
        XCTAssertGreaterThanOrEqual(hooks.count, 2, "repeated part labeled Hook")

        // ordered + covers full track
        for i in 1..<result.sections.count {
            XCTAssertGreaterThanOrEqual(result.sections[i].start, result.sections[i - 1].start)
        }
        XCTAssertLessThan(abs(result.sections.last!.end - Double(makeSong().count) / SR), 1.0, "covers full track")

        // confidence present on every section
        XCTAssertTrue(result.sections.allSatisfy { $0.confidence > 0 })
    }

    func testTinyInputHandledGracefully() {
        let tiny = [Float](repeating: 0, count: Int(SR))
        let result = Segmentation.segment(tiny, sampleRate: SR)
        XCTAssertGreaterThanOrEqual(result.sections.count, 1, "tiny input yields >=1 section without crashing")
    }
}
