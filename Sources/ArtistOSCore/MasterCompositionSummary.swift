import Foundation

public extension MasterComposition {
    /// Canonical artist-facing completion summary for the current song blueprint.
    /// Compatibility Song fields may cache these values, but they are never the authority.
    var lockedProgress: Double {
        guard !sections.isEmpty else { return 0 }
        let lockedCount = sections.filter { $0.state == .locked }.count
        return Double(lockedCount) / Double(sections.count)
    }

    /// Canonical artist-facing risk summary for the current song blueprint.
    var riskSummary: String {
        guard !sections.isEmpty else { return "In assembly" }

        let unresolved = sections.filter { $0.state == .needsDecision }
        if !unresolved.isEmpty {
            return "\(unresolved.map(\.name).joined(separator: ", ")) decision unresolved"
        }

        return sections.allSatisfy { $0.state == .locked }
            ? "Master locked"
            : "In assembly"
    }
}
