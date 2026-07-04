import XCTest
@testable import ArtistOS

final class AudioAnalysisTests: XCTestCase { // mirrors tests/web/audio.test.js
    private let sampleRate = 22050.0

    private func clickTrack(bpm: Double, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(sampleRate * seconds))
        let period = 60.0 / bpm
        var beat = 0.0
        while beat * period < seconds {
            let at = Int(beat * period * sampleRate)
            for i in 0..<400 where at + i < samples.count {
                samples[at + i] = Float(sin(2 * .pi * 1000 * Double(i) / sampleRate) * exp(-Double(i) / 60))
            }
            beat += 1
        }
        return samples
    }

    private func triad(_ freqs: [Double], seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(sampleRate * seconds))
        for f in freqs {
            for i in 0..<samples.count {
                samples[i] += Float(sin(2 * .pi * f * Double(i) / sampleRate) / 3)
            }
        }
        return samples
    }

    func test120BPMClickTrack() {
        let tempo = AudioAnalysis.detectBPM(clickTrack(bpm: 120, seconds: 8), sampleRate: sampleRate)
        XCTAssertNotNil(tempo)
        XCTAssertEqual(tempo!.bpm, 120, accuracy: 2)
        XCTAssertGreaterThan(tempo!.confidence, 0.1)
    }

    func test92BPMOctaveFold() {
        let tempo = AudioAnalysis.detectBPM(clickTrack(bpm: 92, seconds: 8), sampleRate: sampleRate)
        XCTAssertNotNil(tempo)
        XCTAssertEqual(tempo!.bpm, 92, accuracy: 2)
    }

    func testAMinorTriad() {
        let key = AudioAnalysis.detectKey(triad([220, 261.63, 329.63], seconds: 6), sampleRate: sampleRate)
        XCTAssertNotNil(key)
        XCTAssertTrue(["A minor", "C major"].contains(key!.name), "got \(key!.name)")
    }

    func testGMajorTriad() {
        let key = AudioAnalysis.detectKey(triad([196, 246.94, 293.66], seconds: 6), sampleRate: sampleRate)
        XCTAssertNotNil(key)
        XCTAssertTrue(["G major", "E minor"].contains(key!.name), "got \(key!.name)")
    }

    func testSilenceRejected() {
        XCTAssertNil(AudioAnalysis.detectBPM([Float](repeating: 0, count: Int(sampleRate * 4)), sampleRate: sampleRate))
    }

    func testFullPipelineOnPreparedSignal() {
        let result = AudioAnalysis.analyze(clickTrack(bpm: 120, seconds: 10), sampleRate: sampleRate)
        XCTAssertNotNil(result.tempo)
        XCTAssertEqual(result.tempo!.bpm, 120, accuracy: 3)
    }
}
