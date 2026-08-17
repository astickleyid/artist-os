import Foundation
import ArtistOSCore
import os

private let approvalLogger = Logger(subsystem: "com.stickley.artistos", category: "Approvals")

@MainActor
extension AppState {
    /// Commits an artist's section-level choice as one unit of truth:
    /// legacy compatibility state + factual events + CreativeDecision +
    /// canonical Master Composition. In-memory state changes only after the
    /// SQLite transaction succeeds.
    func approveSectionDecision(
        sectionID: UUID,
        songID: UUID,
        winner: UUID,
        rejectedAssetIDs: [UUID] = [],
        reason: String? = nil
    ) {
        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == songID }),
              let sectionIndex = catalog.songs[songIndex].sections.firstIndex(where: { $0.id == sectionID }),
              let winnerAsset = catalog.assets.first(where: { $0.id == winner && $0.songID == songID })
        else { return }

        let oldSection = catalog.songs[songIndex].sections[sectionIndex]
        guard oldSection.assetID != winner || oldSection.state != .locked else { return }

        let timestamp = Date()
        let target = approvalTarget(forSectionName: oldSection.name)
        var updatedSong = catalog.songs[songIndex]
        updatedSong.sections[sectionIndex].assetID = winner
        updatedSong.sections[sectionIndex].state = .locked
        updatedSong.sections[sectionIndex].confidence = max(updatedSong.sections[sectionIndex].confidence, 0.9)
        recomputeApprovalProgress(&updatedSong)
        updatedSong.updatedAt = timestamp

        var events: [CreativeEvent] = []
        if oldSection.assetID != winner {
            events.append(CreativeEvent(
                id: UUID(),
                songID: songID,
                timestamp: timestamp,
                target: target,
                operation: .sourceSelected,
                beforeAssetID: oldSection.assetID,
                afterAssetID: winner,
                summary: "\(winnerAsset.title) selected as \(oldSection.name) source.",
                confidence: 1
            ))
        }
        if oldSection.state != .locked {
            events.append(CreativeEvent(
                id: UUID(),
                songID: songID,
                timestamp: timestamp,
                target: target,
                operation: .approved,
                beforeAssetID: oldSection.assetID,
                afterAssetID: winner,
                summary: "\(oldSection.name) moved from \(oldSection.state.rawValue) to Locked.",
                confidence: 1
            ))
        }

        let rejected = normalizedRejectedAssetIDs(
            rejectedAssetIDs,
            winner: winner,
            songID: songID
        )
        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: target,
            action: .approved,
            selectedAssetID: winner,
            rejectedAssetIDs: rejected,
            relatedEventIDs: events.map(\.id),
            reason: reason,
            source: .artist
        )

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: updatedSong)
        guard let compositionSectionIndex = composition.sections.firstIndex(where: { $0.id == sectionID })
        else { return }

        composition.sections[compositionSectionIndex].setSelection(MasterSelection(
            kind: .sourceAsset,
            referenceID: winner,
            decisionID: decision.id,
            selectedAt: timestamp
        ))
        composition.sections[compositionSectionIndex].state = .locked
        composition.sections[compositionSectionIndex].confidence = max(
            composition.sections[compositionSectionIndex].confidence,
            0.9
        )
        composition.updatedAt = timestamp

        do {
            try store.commitApproval(
                song: updatedSong,
                events: events,
                decision: decision,
                masterComposition: composition
            )
        } catch {
            approvalLogger.error("Section approval transaction failed: \(error.localizedDescription)")
            return
        }

        catalog.songs[songIndex] = updatedSong
        catalog.events.append(contentsOf: events)
        catalog.decisions.append(decision)
        catalog.setMasterComposition(composition)
        syncCanonicalApprovalState(
            song: updatedSong,
            events: events,
            decision: decision,
            composition: composition
        )
    }

    /// Commits an artist's chosen current full-song master. The canonical
    /// Master Composition output, legacy master pointer, factual event, and
    /// Decision are persisted atomically.
    func approveMasterDecision(
        songID: UUID,
        assetID: UUID,
        rejectedAssetIDs: [UUID] = [],
        reason: String? = nil
    ) {
        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == songID }),
              let asset = catalog.assets.first(where: { $0.id == assetID && $0.songID == songID })
        else { return }

        let oldMasterID = catalog.songs[songIndex].masterAssetID
        guard oldMasterID != assetID else { return }

        let timestamp = Date()
        var updatedSong = catalog.songs[songIndex]
        updatedSong.masterAssetID = assetID
        updatedSong.updatedAt = timestamp

        let event = CreativeEvent(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: .master,
            operation: .approved,
            beforeAssetID: oldMasterID,
            afterAssetID: assetID,
            summary: "\(asset.title) pinned as current master.",
            confidence: 1
        )

        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: .master,
            action: .approved,
            selectedAssetID: assetID,
            rejectedAssetIDs: normalizedRejectedAssetIDs(
                rejectedAssetIDs,
                winner: assetID,
                songID: songID
            ),
            relatedEventIDs: [event.id],
            reason: reason,
            source: .artist
        )

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: updatedSong)
        composition.outputAssetID = assetID
        composition.updatedAt = timestamp

        do {
            try store.commitApproval(
                song: updatedSong,
                events: [event],
                decision: decision,
                masterComposition: composition
            )
        } catch {
            approvalLogger.error("Master approval transaction failed: \(error.localizedDescription)")
            return
        }

        catalog.songs[songIndex] = updatedSong
        catalog.events.append(event)
        catalog.decisions.append(decision)
        catalog.setMasterComposition(composition)
        syncCanonicalApprovalState(
            song: updatedSong,
            events: [event],
            decision: decision,
            composition: composition
        )
    }

    /// Approval state is one canonical unit across devices: compatibility Song,
    /// factual Events, the artist Decision, and the resulting Master Composition.
    /// Push all four together so a remote device never receives WHAT without WHY
    /// or a Decision without the canonical state it authorized.
    private func syncCanonicalApprovalState(
        song: Song,
        events: [CreativeEvent],
        decision: CreativeDecision,
        composition: MasterComposition
    ) {
        guard syncStatus == .on else { return }
        let changes = [SyncLogic.change(forSong: song)]
            + events.map(SyncLogic.change(forEvent:))
            + [
                SyncLogic.change(forDecision: decision),
                SyncLogic.change(forMasterComposition: composition)
            ]
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sync.push(changes: changes)
                self.syncLastError = nil
            } catch {
                self.syncLastError = error.localizedDescription
            }
        }
    }

    private func normalizedRejectedAssetIDs(
        _ ids: [UUID],
        winner: UUID,
        songID: UUID
    ) -> [UUID] {
        let valid = Set(catalog.assets.filter { $0.songID == songID }.map(\.id))
        var seen = Set<UUID>()
        return ids.filter { id in
            guard id != winner, valid.contains(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private func recomputeApprovalProgress(_ song: inout Song) {
        guard !song.sections.isEmpty else {
            song.progress = 0
            song.risk = "In assembly"
            return
        }
        let locked = song.sections.filter { $0.state == .locked }.count
        song.progress = Double(locked) / Double(song.sections.count)
        let unresolved = song.sections.filter { $0.state == .needsDecision }
        song.risk = unresolved.isEmpty
            ? (locked == song.sections.count ? "Master locked" : "In assembly")
            : "\(unresolved.map(\.name).joined(separator: ", ")) decision unresolved"
    }

    private func approvalTarget(forSectionName name: String) -> EventTarget {
        let lower = name.lowercased()
        if lower.contains("intro") { return .intro }
        if lower.contains("verse") { return .verse }
        if lower.contains("hook") || lower.contains("chorus") { return .hook }
        if lower.contains("bridge") { return .bridge }
        return .song
    }
}
