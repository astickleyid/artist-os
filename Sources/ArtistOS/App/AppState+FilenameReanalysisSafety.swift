import Foundation
import ArtistOSCore

@MainActor
extension AppState {
    /// Runs the legacy filename regrouping pass only when it cannot move an Asset
    /// that canonical Master Composition currently references or delete a Song
    /// whose canonical composition still contains current asset references.
    ///
    /// This is intentionally conservative while `reanalyzeCatalog()` still owns
    /// the regroup implementation. Canonical truth wins over compatibility Song
    /// mirrors, so an unsafe pass is skipped rather than risking catalog damage.
    @discardableResult
    func reanalyzeCatalogSafely() -> Bool {
        guard canRunFilenameReanalysisSafely() else { return false }
        reanalyzeCatalog()
        return true
    }

    /// Internal for regression coverage. Returns false when the current legacy
    /// regroup algorithm could contradict canonical Master Composition truth.
    func canRunFilenameReanalysisSafely() -> Bool {
        struct CandidateMove {
            let assetID: UUID
            let homeSongID: UUID
        }

        let candidateMoves: [CandidateMove] = catalog.assets.compactMap { asset in
            guard let homeID = asset.songID,
                  let home = catalog.songs.first(where: { $0.id == homeID })
            else { return nil }

            let parsed = VersionIntelligence.parse(asset.originalFilename)
            guard home.title.caseInsensitiveCompare(parsed.canonical) != .orderedSame
            else { return nil }

            return CandidateMove(assetID: asset.id, homeSongID: homeID)
        }

        guard !candidateMoves.isEmpty else { return true }

        // Asset ownership is compatibility metadata during migration. A stale
        // `songID` must not let filename regrouping move an Asset that any Song's
        // canonical Master Composition currently references.
        for move in candidateMoves where canonicalCompositionReferencesAsset(move.assetID) {
            return false
        }

        let movesBySong = Dictionary(grouping: candidateMoves, by: \.homeSongID)
        for (songID, moves) in movesBySong {
            let movingAssetIDs = Set(moves.map(\.assetID))
            let hasRemainingOwnedAsset = catalog.assets.contains {
                $0.songID == songID && !movingAssetIDs.contains($0.id)
            }

            if !hasRemainingOwnedAsset && canonicalCompositionHasAssetReferences(songID: songID) {
                return false
            }
        }

        return true
    }

    private func canonicalCompositionReferencesAsset(_ assetID: UUID) -> Bool {
        catalog.songs.contains { song in
            canonicalComposition(songID: song.id, references: assetID)
        }
    }

    private func canonicalComposition(songID: UUID, references assetID: UUID) -> Bool {
        guard let composition = catalog.masterComposition(for: songID) else { return false }
        if composition.outputAssetID == assetID { return true }
        return composition.sections.contains {
            $0.selection(.sourceAsset)?.referenceID == assetID
        }
    }

    private func canonicalCompositionHasAssetReferences(songID: UUID) -> Bool {
        guard let composition = catalog.masterComposition(for: songID) else { return false }
        if composition.outputAssetID != nil { return true }
        return composition.sections.contains {
            $0.selection(.sourceAsset) != nil
        }
    }
}
