import Foundation

/// Candidate filtering and ranking for artist A/B decisions.
///
/// A canonical Master Composition section may declare a role that maps directly
/// to an AssetRole (for example Hook, Bridge, or Lead Vocal). When it does,
/// comparisons should not offer obviously unrelated assets such as full mixes
/// or reference tracks. The currently selected source is always retained even
/// if its imported role metadata is stale, because canonical truth outranks
/// inferred metadata.
public enum ComparisonIntelligence {
    public static func candidates(
        for section: MasterCompositionSection,
        assets: [Asset]
    ) -> [Asset] {
        guard let expectedRole = AssetRole(rawValue: section.role) else {
            return assets
        }

        let currentSourceID = section.selection(.sourceAsset)?.referenceID
        return assets.filter { asset in
            asset.role == expectedRole || asset.id == currentSourceID
        }
    }

    /// Orders the filtered comparison set around the artist's current intent.
    /// The canonical source stays first, while challengers use the same version
    /// recency rules as the rest of Artist OS so the most likely next take is
    /// offered before older alternatives.
    public static func rankedCandidates(
        for section: MasterCompositionSection,
        assets: [Asset]
    ) -> [Asset] {
        let filtered = candidates(for: section, assets: assets)
        let currentSourceID = section.selection(.sourceAsset)?.referenceID
        let current = currentSourceID.flatMap { id in
            filtered.first(where: { $0.id == id })
        }
        let challengers = VersionIntelligence.sortVersions(
            filtered.filter { $0.id != currentSourceID }
        )

        if let current {
            return [current] + challengers
        }
        return challengers
    }
}
