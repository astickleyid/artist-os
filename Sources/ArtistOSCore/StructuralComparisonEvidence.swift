import Foundation

/// Factual comparison of two audio segmentation results.
///
/// Segmentation is derived analysis, not catalog truth. This helper only
/// describes detector output so an artist knows where to listen more closely;
/// it never changes candidate ranking or claims that an arrangement is better.
public enum StructuralComparisonEvidence {
    /// Summarizes meaningful detector differences between two segmentations.
    /// Returns nil when there is not enough structural evidence to say anything useful.
    public static func summary(between a: Segmentation.Result, and b: Segmentation.Result) -> String? {
        let sectionsA = a.sections
        let sectionsB = b.sections
        guard !sectionsA.isEmpty, !sectionsB.isEmpty else { return nil }

        var parts: [String] = []

        if sectionsA.count != sectionsB.count {
            parts.append("Detected sections \(sectionsA.count) → \(sectionsB.count)")
        }

        if a.clusterCount != b.clusterCount {
            parts.append("repetition groups \(a.clusterCount) → \(b.clusterCount)")
        }

        if sectionsA.count == sectionsB.count, sectionsA.count > 1,
           let maximumShift = maximumNormalizedBoundaryShift(sectionsA, sectionsB) {
            if maximumShift < 0.03 {
                parts.append("similar boundary pattern")
            } else if maximumShift >= 0.08 {
                let percent = Int((maximumShift * 100).rounded())
                parts.append("boundary pattern shifts up to \(percent)% of runtime")
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private static func maximumNormalizedBoundaryShift(
        _ a: [Segmentation.Section],
        _ b: [Segmentation.Section]
    ) -> Double? {
        guard let durationA = a.last?.end,
              let durationB = b.last?.end,
              durationA.isFinite, durationA > 0,
              durationB.isFinite, durationB > 0 else { return nil }

        let boundariesA = a.dropLast().map { $0.end / durationA }
        let boundariesB = b.dropLast().map { $0.end / durationB }
        guard boundariesA.count == boundariesB.count, !boundariesA.isEmpty else { return nil }

        return zip(boundariesA, boundariesB)
            .map { abs($0 - $1) }
            .max()
    }
}
