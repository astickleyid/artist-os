import Foundation

/// Candidate filtering for artist A/B decisions.
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
}
