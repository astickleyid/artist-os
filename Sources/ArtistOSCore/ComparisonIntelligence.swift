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
    public enum SurfacingReason: Equatable {
        case currentCanonicalSource
        case highestVersionLabel(Int)
        case mostRecentlyModified
        case mostRecentlyImported
        case alternative

        public var explanation: String {
            switch self {
            case .currentCanonicalSource:
                return "Current canonical source"
            case .highestVersionLabel(let version):
                return "Newest version label (v\(version))"
            case .mostRecentlyModified:
                return "Most recently modified relevant take"
            case .mostRecentlyImported:
                return "Most recently imported relevant take"
            case .alternative:
                return "Relevant alternate take"
            }
        }
    }

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

    /// Explains why a candidate is being surfaced without making a quality
    /// judgment. Artist OS may use version/recency metadata to order candidates,
    /// but the artist still decides which recording is actually better.
    public static func surfacingReason(
        for asset: Asset,
        section: MasterCompositionSection,
        assets: [Asset]
    ) -> SurfacingReason {
        let filtered = candidates(for: section, assets: assets)
        let currentSourceID = section.selection(.sourceAsset)?.referenceID
        if asset.id == currentSourceID {
            return .currentCanonicalSource
        }

        let challengers = filtered.filter { $0.id != currentSourceID }
        guard VersionIntelligence.sortVersions(challengers).first?.id == asset.id else {
            return .alternative
        }

        let versionOrders = challengers.compactMap(\.vOrder)
        if let order = asset.vOrder,
           versionOrders.contains(where: { $0 != order }),
           order == versionOrders.max() {
            return .highestVersionLabel(order)
        }

        let modifiedDates = challengers.compactMap(\.fileModifiedAt)
        if let modifiedAt = asset.fileModifiedAt,
           modifiedDates.contains(where: { $0 != modifiedAt }),
           modifiedAt == modifiedDates.max() {
            return .mostRecentlyModified
        }

        if challengers.contains(where: { $0.createdAt != asset.createdAt }) {
            return .mostRecentlyImported
        }

        return .alternative
    }
}
