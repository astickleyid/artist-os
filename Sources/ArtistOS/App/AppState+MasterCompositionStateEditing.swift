import Foundation
import ArtistOSCore
import os

private let masterStateEditingLogger = Logger(
    subsystem: "com.stickley.artistos",
    category: "MasterCompositionStateEditing"
)

@MainActor
extension AppState {
    /// Reorders a master slot in canonical truth without rewriting legacy
    /// Song.sections membership or order. Legacy structure is migration-only
    /// compatibility data and must not block a valid canonical reorder.
    func moveCanonicalSection(sectionID: UUID, songID: UUID, offset: Int) {
        guard offset != 0,
              let songIndex = catalog.songs.firstIndex(where: { $0.id == songID })
        else { return }

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: catalog.songs[songIndex])
        guard let canonicalIndex = composition.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let destination = canonicalIndex + offset
        guard destination >= 0, destination < composition.sections.count else { return }

        let timestamp = Date()
        composition.sections.swapAt(canonicalIndex, destination)
        composition.updatedAt = timestamp

        var updatedSong = catalog.songs[songIndex]
        updatedSong.updatedAt = timestamp

        let section = composition.sections[destination]
        let event = CreativeEvent(
            id: UUID(), songID: songID, timestamp: timestamp,
            target: .song, operation: .structureUpdated,
            beforeAssetID: nil, afterAssetID: nil,
            summary: "\(section.name) moved to position \(destination + 1).",
            confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: timestamp,
            target: .song, action: .approved,
            selectedAssetID: nil, rejectedAssetIDs: [],
            relatedEventIDs: [event.id],
            reason: "Moved \(section.name) to position \(destination + 1) in the current song structure.",
            source: .artist
        )

        commitCanonicalMasterStateEdit(
            song: updatedSong,
            event: event,
            decision: decision,
            composition: composition,
            failureMessage: "Move master slot transaction failed"
        )
    }

    /// Updates workflow state in canonical Master Composition. Song-level
    /// progress/risk remain compatibility summaries, but legacy section state
    /// and confidence are no longer rewritten during canonical edits.
    func setCanonicalSectionState(_ newState: SectionState, sectionID: UUID, songID: UUID) {
        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == songID }) else { return }

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: catalog.songs[songIndex])
        guard let canonicalIndex = composition.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let oldState = composition.sections[canonicalIndex].state
        guard oldState != newState else { return }

        var updatedSong = catalog.songs[songIndex]

        let timestamp = Date()
        composition.sections[canonicalIndex].state = newState
        if newState == .locked {
            composition.sections[canonicalIndex].confidence = max(composition.sections[canonicalIndex].confidence, 0.9)
        }
        composition.updatedAt = timestamp
        recomputeCanonicalMasterProgress(&updatedSong, composition: composition)
        updatedSong.updatedAt = timestamp

        let section = composition.sections[canonicalIndex]
        // Permanent state-change history must describe canonical truth. The
        // legacy Song source is only a compatibility mirror and may be stale.
        let selectedAssetID = section.selection(.sourceAsset)?.referenceID
        let event = CreativeEvent(
            id: UUID(), songID: songID, timestamp: timestamp,
            target: canonicalMasterTarget(forSectionName: section.name),
            operation: canonicalOperation(for: newState),
            beforeAssetID: selectedAssetID, afterAssetID: selectedAssetID,
            summary: "\(section.name) moved from \(oldState.rawValue) to \(newState.rawValue).",
            confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(), songID: songID, timestamp: timestamp,
            target: canonicalMasterTarget(forSectionName: section.name),
            action: canonicalDecisionAction(for: newState),
            selectedAssetID: selectedAssetID, rejectedAssetIDs: [],
            relatedEventIDs: [event.id],
            reason: "Set \(section.name) to \(newState.rawValue).",
            source: .artist
        )

        commitCanonicalMasterStateEdit(
            song: updatedSong,
            event: event,
            decision: decision,
            composition: composition,
            failureMessage: "Set master slot state transaction failed"
        )
    }

    private func commitCanonicalMasterStateEdit(
        song: Song,
        event: CreativeEvent,
        decision: CreativeDecision,
        composition: MasterComposition,
        failureMessage: String
    ) {
        let syncChanges: [SyncLogic.JSONDict] = syncStatus == .on
            ? [
                SyncLogic.change(forSong: song),
                SyncLogic.change(forEvent: event),
                SyncLogic.change(forDecision: decision),
                SyncLogic.change(forMasterComposition: composition)
            ]
            : []

        do {
            try store.commitApproval(
                song: song,
                events: [event],
                decision: decision,
                masterComposition: composition,
                syncChanges: syncChanges
            )
        } catch {
            masterStateEditingLogger.error("\(failureMessage): \(error.localizedDescription)")
            return
        }

        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == song.id }) else { return }
        catalog.songs[songIndex] = song
        catalog.events.append(event)
        catalog.decisions.append(decision)
        catalog.setMasterComposition(composition)

        if !syncChanges.isEmpty {
            resumeCanonicalSyncOutbox()
        }
    }

    /// Song progress/risk remain compatibility summary fields, but their value
    /// must be derived from canonical Master Composition state. A stale legacy
    /// section mirror must never regain authority over artist-facing progress.
    private func recomputeCanonicalMasterProgress(
        _ song: inout Song,
        composition: MasterComposition
    ) {
        guard !composition.sections.isEmpty else {
            song.progress = 0
            song.risk = "In assembly"
            return
        }
        let locked = composition.sections.filter { $0.state == .locked }.count
        song.progress = Double(locked) / Double(composition.sections.count)
        let unresolved = composition.sections.filter { $0.state == .needsDecision }
        song.risk = unresolved.isEmpty
            ? (locked == composition.sections.count ? "Master locked" : "In assembly")
            : "\(unresolved.map(\.name).joined(separator: ", ")) decision unresolved"
    }

    private func canonicalOperation(for state: SectionState) -> EventOperation {
        switch state {
        case .locked: return .approved
        case .needsDecision: return .needsDecision
        case .candidate: return .candidateAdded
        case .experiment, .open: return .structureUpdated
        }
    }

    private func canonicalDecisionAction(for state: SectionState) -> DecisionAction {
        switch state {
        case .locked: return .approved
        case .candidate: return .selected
        case .needsDecision, .experiment: return .deferred
        case .open: return .reverted
        }
    }

    private func canonicalMasterTarget(forSectionName name: String) -> EventTarget {
        let lower = name.lowercased()
        if lower.contains("intro") { return .intro }
        if lower.contains("verse") { return .verse }
        if lower.contains("hook") || lower.contains("chorus") { return .hook }
        if lower.contains("bridge") { return .bridge }
        return .song
    }
}
