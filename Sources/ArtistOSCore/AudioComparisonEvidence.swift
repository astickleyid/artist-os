import Foundation

/// Factual audio-analysis context for A/B decisions.
///
/// This deliberately does not rank or score candidates. It only exposes
/// already-observed metadata so the artist can listen with useful context
/// without Artist OS implying that a tempo, key, or duration is "better."
public enum AudioComparisonEvidence {
    public static func summary(for asset: Asset) -> String? {
        var parts: [String] = []

        if let bpm = asset.bpm, bpm.isFinite, bpm > 0 {
            let rounded = bpm.rounded()
            if abs(bpm - rounded) < 0.05 {
                parts.append("\(Int(rounded)) BPM")
            } else {
                parts.append(String(format: "%.1f BPM", bpm))
            }
        }

        if let key = asset.musicalKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            parts.append(key)
        }

        if let duration = asset.duration, duration.isFinite, duration > 0 {
            let totalSeconds = Int(duration.rounded())
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            parts.append(String(format: "%d:%02d", minutes, seconds))
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
