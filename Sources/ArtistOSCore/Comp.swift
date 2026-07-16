import Foundation

/// Quick Swipe Comp engine — Logic-style comping across song versions.
/// Multiple source versions share ONE timeline; swiping a time-range on a
/// source makes it active over that range. The comp is the assembled result:
/// ordered, non-overlapping segments covering the timeline, each pointing at
/// the source that wins there (last swipe wins). MUST match docs/comp.js.
public enum Comp {

    public struct Segment: Equatable {
        public var sourceId: String
        public var start: Double
        public var end: Double
        public init(sourceId: String, start: Double, end: Double) {
            self.sourceId = sourceId; self.start = start; self.end = end
        }
    }

    public struct Model: Equatable {
        public var duration: Double
        public var segments: [Segment]
        public init(duration: Double, segments: [Segment]) {
            self.duration = duration; self.segments = segments
        }
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }

    public static func makeComp(duration: Double, defaultSourceId: String) -> Model {
        Model(duration: duration, segments: [Segment(sourceId: defaultSourceId, start: 0, end: duration)])
    }

    static func mergeAdjacent(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segments {
            if var last = out.last, last.sourceId == s.sourceId, abs(last.end - s.start) < 1e-6 {
                last.end = s.end
                out[out.count - 1] = last
            } else {
                out.append(Segment(sourceId: s.sourceId, start: s.start, end: s.end))
            }
        }
        return out
    }

    /// Assign [from,to] to sourceId, splitting overlapped segments. Pure.
    public static func applySwipe(_ comp: Model, sourceId: String, from rawFrom: Double, to rawTo: Double) -> Model {
        let dur = comp.duration
        let from = clamp(min(rawFrom, rawTo), 0, dur)
        let to = clamp(max(rawFrom, rawTo), 0, dur)
        if to - from < 1e-6 { return Model(duration: dur, segments: comp.segments) }

        var result: [Segment] = []
        for seg in comp.segments {
            if seg.end <= from || seg.start >= to { result.append(seg); continue }
            if seg.start < from { result.append(Segment(sourceId: seg.sourceId, start: seg.start, end: from)) }
            if seg.end > to { result.append(Segment(sourceId: seg.sourceId, start: to, end: seg.end)) }
        }
        result.append(Segment(sourceId: sourceId, start: from, end: to))
        result.sort { $0.start < $1.start }
        return Model(duration: dur, segments: mergeAdjacent(result))
    }

    public static func sourceAt(_ comp: Model, _ t: Double) -> String? {
        for s in comp.segments where t >= s.start && t < s.end { return s.sourceId }
        return comp.segments.last?.sourceId
    }

    /// Interior transition times — where crossfades happen.
    public static func boundaries(_ comp: Model) -> [Double] {
        guard comp.segments.count > 1 else { return [] }
        return comp.segments.dropFirst().map { $0.start }
    }

    public static func coverage(_ comp: Model) -> [String: Double] {
        var map: [String: Double] = [:]
        for s in comp.segments { map[s.sourceId, default: 0] += (s.end - s.start) }
        return map
    }

    public static func sourcesUsed(_ comp: Model) -> Int {
        Set(comp.segments.map { $0.sourceId }).count
    }

    /// Loudness matching: per-source gain normalizing every source to the
    /// loudest source's RMS (never boosts above ~+12 dB).
    public static func loudnessGains(_ rms: [String: Double]) -> [String: Double] {
        let vals = rms.values.filter { $0 > 0 }
        guard let target = vals.max() else { return [:] }
        var gains: [String: Double] = [:]
        for (id, r) in rms { gains[id] = r > 0 ? min(4, target / r) : 1 }
        return gains
    }
}
