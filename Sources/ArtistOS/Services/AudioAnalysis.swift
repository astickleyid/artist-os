import Foundation
import AVFoundation

/// Pure DSP mirroring docs/audio-intel.js (VISION.md contract):
/// tempo via onset-energy autocorrelation, key via Krumhansl-Schmuckler.
enum AudioAnalysis {

    struct Tempo: Equatable { var bpm: Double; var confidence: Double }
    struct Key: Equatable { var name: String; var confidence: Double }
    struct Result { var tempo: Tempo?; var key: Key? }

    static let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let ksMajor: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let ksMinor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    // MARK: - Tempo

    static func detectBPM(_ samples: [Float], sampleRate: Double) -> Tempo? {
        let hop = 512
        let nFrames = samples.count / hop
        guard nFrames >= 32 else { return nil }

        var flux = [Double](repeating: 0, count: nFrames)
        var prev = 0.0
        for i in 0..<nFrames {
            var e = 0.0
            let off = i * hop
            for j in 0..<hop { let s = Double(samples[off + j]); e += s * s }
            flux[i] = max(0, e - prev)
            prev = e
        }
        let mean = flux.reduce(0, +) / Double(nFrames)
        guard mean > 0 else { return nil }
        for i in 0..<nFrames { flux[i] /= mean }

        let fps = sampleRate / Double(hop)
        let minLag = max(2, Int(fps * 60 / 190))
        let maxLag = min(nFrames - 2, Int((fps * 60 / 55).rounded(.up)))
        guard maxLag > minLag else { return nil }

        var bestLag = minLag, bestScore = -1.0, total = 0.0
        for lag in minLag...maxLag {
            var score = 0.0
            var i = 0
            while i + lag < nFrames { score += flux[i] * flux[i + lag]; i += 1 }
            score /= Double(nFrames - lag)
            total += score
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        var bpm = 60 * fps / Double(bestLag)
        while bpm < 70 { bpm *= 2 }
        while bpm > 180 { bpm /= 2 }
        let avg = total / Double(maxLag - minLag + 1)
        let confidence = avg > 0 ? min(1, (bestScore / avg - 1) / 4) : 0
        guard confidence >= 0.05 else { return nil }
        return Tempo(bpm: (bpm * 10).rounded() / 10, confidence: (confidence * 100).rounded() / 100)
    }

    // MARK: - Key

    private static func goertzel(_ samples: [Float], offset: Int, length: Int, freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<length {
            let s0 = Double(samples[offset + i]) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        return (s1 * s1 + s2 * s2 - coeff * s1 * s2).squareRoot()
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = (da * db).squareRoot()
        return den > 0 ? num / den : 0
    }

    static func detectKey(_ samples: [Float], sampleRate: Double) -> Key? {
        let frame = 4096, hop = 2048
        guard samples.count >= frame * 2 else { return nil }

        var freqs: [(pc: Int, f: Double)] = []
        for midi in 36...83 {
            freqs.append((midi % 12, 440 * pow(2, Double(midi - 69) / 12)))
        }
        var chroma = [Double](repeating: 0, count: 12)
        let nFrames = (samples.count - frame) / hop + 1
        for i in 0..<nFrames {
            let off = i * hop
            for (pc, f) in freqs where f < sampleRate / 2 - 100 {
                chroma[pc] += goertzel(samples, offset: off, length: frame, freq: f, sampleRate: sampleRate)
            }
        }
        guard let peak = chroma.max(), peak > 0 else { return nil }
        let norm = chroma.map { $0 / peak }

        var best: (root: Int, mode: String, corr: Double)?
        for root in 0..<12 {
            func rotated(_ profile: [Double]) -> [Double] {
                (0..<12).map { profile[(($0 - root) % 12 + 12) % 12] }
            }
            let cMaj = correlation(norm, rotated(ksMajor))
            let cMin = correlation(norm, rotated(ksMinor))
            if best == nil || cMaj > best!.corr { best = (root, "major", cMaj) }
            if cMin > best!.corr { best = (root, "minor", cMin) }
        }
        guard let b = best, b.corr >= 0.35 else { return nil }
        return Key(name: "\(pitchNames[b.root]) \(b.mode)", confidence: (b.corr * 100).rounded() / 100)
    }

    // MARK: - Pipeline

    static func prepare(_ samples: [Float], sampleRate: Double,
                        maxSeconds: Double = 45, targetRate: Double = 11025) -> (samples: [Float], sampleRate: Double) {
        let stride = max(1, Int((sampleRate / targetRate).rounded()))
        var start = 0, end = samples.count
        let maxLen = Int(maxSeconds * sampleRate)
        if end - start > maxLen {
            start = (end - maxLen) / 2
            end = start + maxLen
        }
        var out = [Float]()
        out.reserveCapacity((end - start) / stride)
        var i = start
        while i < end { out.append(samples[i]); i += stride }
        return (out, sampleRate / Double(stride))
    }

    static func analyze(_ samples: [Float], sampleRate: Double) -> Result {
        let p = prepare(samples, sampleRate: sampleRate)
        return Result(
            tempo: detectBPM(p.samples, sampleRate: p.sampleRate),
            key: detectKey(p.samples, sampleRate: p.sampleRate)
        )
    }

    /// Reads mono Float32 PCM from a local audio file (capped) for analysis.
    static func loadSamples(url: URL, maxBytes: Int = 40 * 1024 * 1024) async -> (samples: [Float], sampleRate: Double)? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes { return nil }
        let avAsset = AVURLAsset(url: url)
        guard let track = try? await avAsset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: avAsset)
        else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 22050
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples = [Float]()
        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { ptr -> OSStatus in
                guard let base = ptr.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            data.withUnsafeBytes { raw in
                samples.append(contentsOf: raw.bindMemory(to: Float.self))
            }
        }
        guard !samples.isEmpty else { return nil }
        return (samples, 22050)
    }
}
