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
    /// Applies filename intelligence selectively: canonical Master Composition
    /// references stay in place while safe candidates are regrouped. Returning
    /// false means some candidates were intentionally protected, not that the
    /// entire pass was discarded.
    @discardableResult
    func reanalyzeCatalogSafely() -> Bool {
        let plan = filenameReanalysisPlan()
        applyFilenameReanalysis(plan)
        return plan.blockedAssetIDs.isEmpty
    }

    /// Produces a mutation-free plan that separates filename regroup candidates
    /// from assets that canonical truth requires Artist OS to keep in place.
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

        // Canonically protected candidates remain in their current Song. Only
        // block the rest of a Song's candidate moves when moving every otherwise-
        // safe owned Asset could leave a canonically meaningful Song with no owned
        // evidence at all.
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

    /// Retained while the legacy all-or-nothing implementation exists for
    /// compatibility and regression coverage.
    func canRunFilenameReanalysisSafely() -> Bool {
        filenameReanalysisPlan().canRunLegacyPass
    }

    private func applyFilenameReanalysis(_ plan: FilenameReanalysisPlan) {
        var touchedSongIDs = Set<UUID>()
        var queuedSync = false

        // Version labels are metadata intelligence, not ownership changes, so they
        // remain safe even for assets whose canonical references block regrouping.
        for assetID in catalog.assets.map(\.id) {
            guard let index = catalog.assets.firstIndex(where: { $0.id == assetID }) else { continue }
            let current = catalog.assets[index]
            let parsed = VersionIntelligence.parse(current.originalFilename)
            guard current.version != parsed.label || current.vOrder != parsed.order else { continue }

            var updated = current
            updated.version = parsed.label
            updated.vOrder = parsed.order
            updated.updatedAt = Date()
            let syncChanges = syncStatus == .on ? [SyncLogic.change(forAsset: updated)] : []
            do {
                try store.commitFilenameReanalysis(asset: updated, syncChanges: syncChanges)
                catalog.assets[index] = updated
                queuedSync = queuedSync || !syncChanges.isEmpty
            } catch {
                // Persistence failure must not leave memory claiming a write that
                // SQLite rejected. Continue with unrelated assets safely.
                continue
            }
        }

        for assetID in plan.movableAssetIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let index = catalog.assets.firstIndex(where: { $0.id == assetID }),
                  let homeID = catalog.assets[index].songID,
                  let home = catalog.songs.first(where: { $0.id == homeID })
            else { continue }

            let current = catalog.assets[index]
            let parsed = VersionIntelligence.parse(current.originalFilename)
            guard home.title.caseInsensitiveCompare(parsed.canonical) != .orderedSame else { continue }

            let createdSong: Song?
            let targetID: UUID
            if let existing = catalog.songs.first(where: {
                $0.title.caseInsensitiveCompare(parsed.canonical) == .orderedSame
            }) {
                createdSong = nil
                targetID = existing.id
            } else {
                let song = ImportService.makeSong(title: parsed.canonical)
                createdSong = song
                targetID = song.id
            }

            var moved = current
            moved.songID = targetID
            moved.updatedAt = Date()

            var events: [CreativeEvent] = []
            if let createdSong {
                events.append(
                    CreativeEvent(
                        id: UUID(), songID: createdSong.id, timestamp: Date(),
                        target: .song, operation: .imported,
                        beforeAssetID: nil, afterAssetID: nil,
                        summary: "\(createdSong.title) created during filename re-analysis.",
                        confidence: 1.0
                    )
                )
            }
            events.append(
                CreativeEvent(
                    id: UUID(), songID: targetID, timestamp: Date(),
                    target: filenameTarget(for: moved.role), operation: .imported,
                    beforeAssetID: nil, afterAssetID: moved.id,
                    summary: "\(moved.originalFilename) regrouped into song (re-analysis).",
                    confidence: 1.0
                )
            )

            var syncChanges: [SyncLogic.JSONDict] = []
            if syncStatus == .on {
                if let createdSong { syncChanges.append(SyncLogic.change(forSong: createdSong)) }
                syncChanges.append(SyncLogic.change(forAsset: moved))
                syncChanges.append(contentsOf: events.map(SyncLogic.change(forEvent:)))
            }

            do {
                try store.commitFilenameReanalysis(
                    asset: moved,
                    createdSong: createdSong,
                    events: events,
                    syncChanges: syncChanges
                )
                if let createdSong { catalog.songs.append(createdSong) }
                catalog.assets[index] = moved
                catalog.events.append(contentsOf: events)
                queuedSync = queuedSync || !syncChanges.isEmpty
                touchedSongIDs.insert(homeID)
                touchedSongIDs.insert(targetID)
            } catch {
                continue
            }
        }

        if !touchedSongIDs.isEmpty {
            runDecisionEngine(songIDs: Array(touchedSongIDs))
        }
        if queuedSync {
            resumeCanonicalSyncOutbox()
        }
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

    private func filenameTarget(for role: AssetRole) -> EventTarget {
        switch role {
        case .fullMix: return .mix
        case .leadVocal: return .leadVocal
        case .beat: return .beat
        case .hook: return .hook
        case .bridge: return .bridge
        case .reference: return .song
        }
    }
}
