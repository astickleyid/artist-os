import Foundation

/// Structural segmentation — finds section boundaries via a self-similarity
/// matrix + Foote novelty, then clusters repeated sections so recurring parts
/// (hook/chorus) are recognized. Proposes labels with confidence; the artist
/// confirms. MUST match docs/segment.js (shared behavior across platforms).
public enum Segmentation {

    public struct Section: Equatable {
        public var index: Int
        public var start: Double
        public var end: Double
        public var label: String
        public var confidence: Double
        public var cluster: Int
        public init(index: Int, start: Double, end: Double, label: String, confidence: Double, cluster: Int) {
            self.index = index; self.start = start; self.end = end
            self.label = label; self.confidence = confidence; self.cluster = cluster
        }
    }

    public struct Options {
        public var hopSeconds: Double = 0.5
        public var kernelHalf: Int? = nil
        public var threshold: Double = 0.22
        public var minSectionSeconds: Double = 6
        public var clusterThreshold: Double = 0.90
        public init() {}
    }

    public struct Result: Equatable {
        public var sections: [Section]
        public var clusterCount: Int
        public var frameCount: Int
    }

    // MARK: - chroma feature sequence

    /// 12-bin chroma per frame (Goertzel over pitch classes C2..B5), L2-normalized.
    static func chromaSequence(_ samples: [Float], sampleRate: Double, hopSeconds: Double) -> [[Double]] {
        let frame = 4096
        let hop = max(1, Int((hopSeconds * sampleRate).rounded()))
        // (pitchClass, freq) for MIDI 36..83
        var freqs: [(pc: Int, f: Double)] = []
        for midi in 36...83 {
            freqs.append((midi % 12, 440.0 * pow(2.0, Double(midi - 69) / 12.0)))
        }
        var frames: [[Double]] = []
        var start = 0
        while start + frame <= samples.count {
            var chroma = [Double](repeating: 0, count: 12)
            for (pc, f) in freqs {
                if f > sampleRate / 2 - 100 { continue }
                let w = 2 * Double.pi * f / sampleRate
                let coeff = 2 * cos(w)
                var s1 = 0.0, s2 = 0.0
                for i in 0..<frame {
                    let s0 = Double(samples[start + i]) + coeff * s1 - s2
                    s2 = s1; s1 = s0
                }
                chroma[pc] += sqrt(max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2))
            }
            var norm = 0.0
            for i in 0..<12 { norm += chroma[i] * chroma[i] }
            norm = norm.squareRoot()
            if norm == 0 { norm = 1 }
            for i in 0..<12 { chroma[i] /= norm }
            frames.append(chroma)
            start += hop
        }
        return frames
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot // frames are L2-normalized
    }

    // MARK: - Foote novelty curve

    static func noveltyCurve(_ frames: [[Double]], kernelHalf: Int?) -> [Double] {
        let n = frames.count
        let L = kernelHalf ?? max(4, Int((Double(n) * 0.06).rounded()))
        let size = 2 * L
        let sigma = Double(L) / 2
        var kernel = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        for i in 0..<size {
            for j in 0..<size {
                let di = Double(i - L) + 0.5, dj = Double(j - L) + 0.5
                let gauss = exp(-(di * di + dj * dj) / (2 * sigma * sigma))
                let sign = ((i < L) == (j < L)) ? 1.0 : -1.0
                kernel[i][j] = sign * gauss
            }
        }
        var novelty = [Double](repeating: 0, count: n)
        for c in 0..<n {
            var sum = 0.0
            for i in 0..<size {
                let fi = c - L + i
                if fi < 0 || fi >= n { continue }
                for j in 0..<size {
                    let fj = c - L + j
                    if fj < 0 || fj >= n { continue }
                    sum += kernel[i][j] * cosine(frames[fi], frames[fj])
                }
            }
            novelty[c] = max(0, sum)
        }
        var maxV = 0.0
        for v in novelty { if v > maxV { maxV = v } }
        if maxV > 0 { for i in 0..<n { novelty[i] /= maxV } }
        return novelty
    }

    // MARK: - peak picking

    static func pickPeaks(_ novelty: [Double], hopSeconds: Double, opts: Options) -> [Int] {
        let minGap = max(1, Int((opts.minSectionSeconds / hopSeconds).rounded()))
        let threshold = opts.threshold
        let n = novelty.count
        var peaks: [Int] = []
        var i = 1
        while i < n - 1 {
            defer { i += 1 }
            if novelty[i] < threshold { continue }
            if novelty[i] >= novelty[i - 1] && novelty[i] > novelty[i + 1] {
                if peaks.isEmpty || i - peaks[peaks.count - 1] >= minGap {
                    peaks.append(i)
                } else if novelty[i] > novelty[peaks[peaks.count - 1]] {
                    peaks[peaks.count - 1] = i
                }
            }
        }
        return peaks
    }

    // MARK: - segments + repetition clustering

    static func averageChroma(_ frames: [[Double]], from: Int, to: Int) -> [Double] {
        var avg = [Double](repeating: 0, count: 12)
        for f in from..<to { for i in 0..<12 { avg[i] += frames[f][i] } }
        var norm = 0.0
        for i in 0..<12 { norm += avg[i] * avg[i] }
        norm = norm.squareRoot()
        if norm == 0 { norm = 1 }
        for i in 0..<12 { avg[i] /= norm }
        return avg
    }

    final class Seg {
        var start: Double; var end: Double; var chroma: [Double]; var cluster: Int = 0
        var label: String = "Section"; var confidence: Double = 0.4
        init(start: Double, end: Double, chroma: [Double]) { self.start = start; self.end = end; self.chroma = chroma }
    }
    final class Cluster {
        var id: Int; var centroid: [Double]; var members: [Seg]
        init(id: Int, centroid: [Double], members: [Seg]) { self.id = id; self.centroid = centroid; self.members = members }
    }

    static func clusterSegments(_ segments: [Seg], simThreshold: Double) -> [Cluster] {
        var clusters: [Cluster] = []
        for seg in segments {
            var placed = false
            for cl in clusters {
                if cosine(seg.chroma, cl.centroid) >= simThreshold {
                    cl.members.append(seg)
                    let m = Double(cl.members.count)
                    for i in 0..<12 { cl.centroid[i] = (cl.centroid[i] * (m - 1) + seg.chroma[i]) / m }
                    var norm = 0.0
                    for i in 0..<12 { norm += cl.centroid[i] * cl.centroid[i] }
                    norm = norm.squareRoot(); if norm == 0 { norm = 1 }
                    for i in 0..<12 { cl.centroid[i] /= norm }
                    seg.cluster = cl.id
                    placed = true
                    break
                }
            }
            if !placed {
                let cl = Cluster(id: clusters.count, centroid: seg.chroma, members: [seg])
                seg.cluster = cl.id
                clusters.append(cl)
            }
        }
        return clusters
    }

    // MARK: - label proposal (honest: proposes with confidence, artist confirms)

    static func proposeLabels(_ segments: [Seg], clusters: [Cluster], totalSeconds: Double) {
        guard !segments.isEmpty else { return }
        let byCount = clusters.sorted { $0.members.count > $1.members.count }
        let hookCluster: Int? = (byCount.first != nil && byCount.first!.members.count >= 2) ? byCount.first!.id : nil

        for (idx, seg) in segments.enumerated() {
            let mid = (seg.start + seg.end) / 2
            let posFrac = totalSeconds > 0 ? mid / totalSeconds : 0
            let dur = seg.end - seg.start
            let clusterSize = clusters.indices.contains(seg.cluster) ? clusters[seg.cluster].members.count : 1

            var label = "Section"; var conf = 0.4
            if idx == 0 && dur < 20 && clusterSize == 1 { label = "Intro"; conf = 0.7 }
            else if seg.cluster == hookCluster { label = "Hook"; conf = 0.72 }
            else if idx == segments.count - 1 && clusterSize == 1 && posFrac > 0.8 { label = "Outro"; conf = 0.6 }
            else if clusterSize == 1 && posFrac >= 0.55 && posFrac <= 0.85 { label = "Bridge"; conf = 0.5 }
            else if clusterSize >= 2 { label = "Verse"; conf = 0.55 }
            else { label = "Verse"; conf = 0.4 }
            seg.label = label
            seg.confidence = conf
        }
    }

    // MARK: - top-level

    public static func segment(_ samples: [Float], sampleRate: Double, options: Options = Options()) -> Result {
        let hopSeconds = options.hopSeconds
        let frames = chromaSequence(samples, sampleRate: sampleRate, hopSeconds: hopSeconds)
        if frames.count < 8 {
            let total = Double(samples.count) / sampleRate
            return Result(sections: [Section(index: 0, start: 0, end: total, label: "Section", confidence: 0.3, cluster: 0)],
                          clusterCount: 1, frameCount: frames.count)
        }
        let novelty = noveltyCurve(frames, kernelHalf: options.kernelHalf)
        let peakFrames = pickPeaks(novelty, hopSeconds: hopSeconds, opts: options)
        let totalSeconds = Double(samples.count) / sampleRate

        var bounds: [Double] = [0]
        bounds.append(contentsOf: peakFrames.map { Double($0) * hopSeconds })
        bounds.append(totalSeconds)

        var segs: [Seg] = []
        for i in 0..<(bounds.count - 1) {
            let start = bounds[i], end = bounds[i + 1]
            let fromF = Int(start / hopSeconds)
            let toF = min(frames.count, max(fromF + 1, Int(end / hopSeconds)))
            segs.append(Seg(start: start, end: end, chroma: averageChroma(frames, from: fromF, to: toF)))
        }
        let clusters = clusterSegments(segs, simThreshold: options.clusterThreshold)
        proposeLabels(segs, clusters: clusters, totalSeconds: totalSeconds)

        let sections = segs.enumerated().map { (i, s) in
            Section(index: i,
                    start: (s.start * 100).rounded() / 100,
                    end: (s.end * 100).rounded() / 100,
                    label: s.label,
                    confidence: (s.confidence * 100).rounded() / 100,
                    cluster: s.cluster)
        }
        return Result(sections: sections, clusterCount: clusters.count, frameCount: frames.count)
    }
}
