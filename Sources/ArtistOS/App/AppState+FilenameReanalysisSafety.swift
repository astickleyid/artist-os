import Foundation
import ArtistOSCore

struct FilenameReanalysisPlan: Equatable {
    let candidateAssetIDs: Set<UUID>
    let blockedAssetIDs: Set<UUID>

    var movableAssetIDs: Set<UUID> {
        candidateAssetIDs.subtracting(blockedAssetIDs)
    }

    var canRunLegacyPass: Bool {
        blockedAssetIDs.isEmpty
    }
}

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

    /// Produces a mutation-free plan that separates filename regroup candidates
    /// from assets that canonical truth requires Artist OS to keep in place.
    ///
    /// The current legacy regroup pass is still all-or-nothing, so any blocked
    /// candidate prevents that pass from running. `movableAssetIDs` is retained
    /// explicitly so a later selective canonical regroup implementation can move
    /// safe assets without re-deriving safety from compatibility mirrors.
    func filenameReanalysisPlan() -> FilenameReanalysisPlan {
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

        let candidateAssetIDs = Set(candidateMoves.map(\.assetID))
        guard !candidateMoves.isEmpty else {
            return FilenameReanalysisPlan(candidateAssetIDs: [], blockedAssetIDs: [])
        }

        // Asset ownership is compatibility metadata during migration. A stale
        // `songID` must not let filename regrouping move an Asset that any Song's
        // canonical Master Composition currently references.
        var blockedAssetIDs = Set(candidateMoves.compactMap { move in
            canonicalCompositionReferencesAsset(move.assetID) ? move.assetID : nil
        })

        // For a future selective pass, canonically protected candidates remain in
        // their current Song. Only block the rest of a Song's candidate moves when
        // moving every otherwise-safe owned Asset could leave a canonically
        // meaningful Song with no owned evidence at all.
        let movesBySong = Dictionary(grouping: candidateMoves, by: \.homeSongID)
        for (songID, moves) in movesBySong {
            let candidateIDsForSong = Set(moves.map(\.assetID))
            let hasRemainingOwnedAsset = catalog.assets.contains { asset in
                guard asset.songID == songID else { return false }
                return !candidateIDsForSong.contains(asset.id) || blockedAssetIDs.contains(asset.id)
            }

            if !hasRemainingOwnedAsset && canonicalCompositionHasAssetReferences(songID: songID) {
                blockedAssetIDs.formUnion(candidateIDsForSong)
            }
        }

        return FilenameReanalysisPlan(
            candidateAssetIDs: candidateAssetIDs,
            blockedAssetIDs: blockedAssetIDs
        )
    }

    /// Internal for regression coverage. Returns false when the current legacy
    /// regroup algorithm could contradict canonical Master Composition truth.
    func canRunFilenameReanalysisSafely() -> Bool {
        filenameReanalysisPlan().canRunLegacyPass
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
