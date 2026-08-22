import Foundation

/// Factual audio-analysis context for A/B decisions.
///
/// This deliberately does not rank or score candidates. It only exposes
/// already-observed metadata so the artist can listen with useful context
/// without Artist OS implying that a tempo, key, or duration is "better."
public enum AudioComparisonEvidence {
    public static func summary(for asset: Asset) -> String? {
        var parts: [String] = []

        if let bpm = validBPM(asset.bpm) {
            parts.append(formatBPM(bpm))
        }

        if let key = normalizedKey(asset.musicalKey) {
            parts.append(key)
        }

        if let duration = validDuration(asset.duration) {
            parts.append(formatDuration(duration))
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Describes measurable A→B differences without assigning quality.
    /// Small tempo/duration differences are treated as materially unchanged
    /// so the comparison UI does not create noise from detector precision.
    public static func relativeSummary(between assetA: Asset, and assetB: Asset) -> String? {
        var parts: [String] = []

        if let bpmA = validBPM(assetA.bpm), let bpmB = validBPM(assetB.bpm) {
            let delta = bpmB - bpmA
            if abs(delta) < 0.5 {
                parts.append("Same detected tempo")
            } else {
                parts.append("B \(formatDelta(abs(delta))) BPM \(delta > 0 ? "faster" : "slower")")
            }
        }

        if let keyA = normalizedKey(assetA.musicalKey),
           let keyB = normalizedKey(assetB.musicalKey) {
            if comparableKeyIdentity(keyA) == comparableKeyIdentity(keyB) {
                parts.append("Same detected key")
            } else {
                parts.append("Key \(keyA) → \(keyB)")
            }
        }

        if let durationA = validDuration(assetA.duration),
           let durationB = validDuration(assetB.duration) {
            let delta = durationB - durationA
            if abs(delta) < 1 {
                parts.append("Same duration")
            } else {
                parts.append("B \(formatDurationDelta(abs(delta))) \(delta > 0 ? "longer" : "shorter")")
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Calls attention to a large duration shift that may deserve an arrangement check.
    /// This is a review signal, not a claim that the arrangement changed or improved.
    /// Both an absolute (8s) and relative (8%) threshold must be crossed so short
    /// detector noise and trivial long-song drift stay out of the artist's way.
    public static func arrangementReviewSignal(between assetA: Asset, and assetB: Asset) -> String? {
        guard let durationA = validDuration(assetA.duration),
              let durationB = validDuration(assetB.duration) else { return nil }

        let delta = durationB - durationA
        let absoluteDelta = abs(delta)
        let relativeDelta = absoluteDelta / durationA
        guard absoluteDelta >= 8, relativeDelta >= 0.08 else { return nil }

        let percent = Int((relativeDelta * 100).rounded())
        return "Arrangement check · B is \(percent)% \(delta > 0 ? "longer" : "shorter")"
    }

    private static func validBPM(_ bpm: Double?) -> Double? {
        guard let bpm, bpm.isFinite, bpm > 0 else { return nil }
        return bpm
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private static func normalizedKey(_ key: String?) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// Comparison-only normalization. Keep the observed spelling for display, but
    /// do not tell the artist that C# and Db are different keys just because two
    /// analyzers/platforms chose different enharmonic spellings.
    private static func comparableKeyIdentity(_ key: String) -> String {
        let normalized = key
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return normalized.lowercased() }

        let pitch = canonicalPitch(String(first))
        let rawMode = parts.dropFirst().joined(separator: " ").lowercased()
        let mode: String
        switch rawMode {
        case "maj": mode = "major"
        case "min": mode = "minor"
        default: mode = rawMode
        }
        return "\(pitch)|\(mode)"
    }

    private static func canonicalPitch(_ pitch: String) -> String {
        switch pitch.lowercased() {
        case "cb": return "b"
        case "c", "b#": return "c"
        case "c#", "db": return "c#"
        case "d": return "d"
        case "d#", "eb": return "d#"
        case "e", "fb": return "e"
        case "e#", "f": return "f"
        case "f#", "gb": return "f#"
        case "g": return "g"
        case "g#", "ab": return "g#"
        case "a": return "a"
        case "a#", "bb": return "a#"
        case "b": return "b"
        default: return pitch.lowercased()
        }
    }

    private static func formatBPM(_ bpm: Double) -> String {
        let rounded = bpm.rounded()
        if abs(bpm - rounded) < 0.05 {
            return "\(Int(rounded)) BPM"
        }
        return String(format: "%.1f BPM", bpm)
    }

    private static func formatDelta(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", value)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func formatDurationDelta(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        return formatDuration(duration)
    }
}
