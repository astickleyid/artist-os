import Foundation
import ArtistOSCore
import os

private let masterEditingLogger = Logger(
    subsystem: "com.stickley.artistos",
    category: "MasterCompositionEditing"
)

@MainActor
extension AppState {
    /// Clears one section's current source as an explicit artist decision while
    /// keeping the legacy Song mirror and canonical Master Composition atomic.
    /// This is the inverse of approveSectionDecision and prevents the workspace
    /// from silently mutating only Song.sections during the migration.
    func clearCanonicalSectionSource(sectionID: UUID, songID: UUID) {
        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == songID }),
              let sectionIndex = catalog.songs[songIndex].sections.firstIndex(where: { $0.id == sectionID })
        else { return }

        let oldSection = catalog.songs[songIndex].sections[sectionIndex]
        let canonicalSourceID = catalog.masterComposition(for: songID)?
            .sections.first(where: { $0.id == sectionID })?
            .selection(.sourceAsset)?.referenceID
        let legacySourceID = oldSection.assetID
        let oldSourceID = canonicalSourceID ?? legacySourceID
        guard oldSourceID != nil else { return }

        let timestamp = Date()
        var updatedSong = catalog.songs[songIndex]
        updatedSong.sections[sectionIndex].assetID = nil
        updatedSong.sections[sectionIndex].state = .open
        updatedSong.sections[sectionIndex].confidence = 0
        recomputeMasterProgress(&updatedSong)
        updatedSong.updatedAt = timestamp

        let target = masterTarget(forSectionName: oldSection.name)
        let event = CreativeEvent(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: target,
            operation: .structureUpdated,
            beforeAssetID: oldSourceID,
            afterAssetID: nil,
            summary: "\(oldSection.name) source cleared.",
            confidence: 1
        )

        var clearedSourceIDs: [UUID] = []
        for id in [canonicalSourceID, legacySourceID].compactMap({ $0 }) where !clearedSourceIDs.contains(id) {
            clearedSourceIDs.append(id)
        }

        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: target,
            action: .reverted,
            selectedAssetID: nil,
            rejectedAssetIDs: clearedSourceIDs,
            relatedEventIDs: [event.id],
            reason: nil,
            source: .artist
        )

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: catalog.songs[songIndex])
        guard let compositionSectionIndex = composition.sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        composition.sections[compositionSectionIndex].clearSelection(.sourceAsset)
        composition.sections[compositionSectionIndex].state = .open
        composition.sections[compositionSectionIndex].confidence = 0
        composition.updatedAt = timestamp

        commitMasterEdit(
            song: updatedSong,
            event: event,
            decision: decision,
            composition: composition,
            failureMessage: "Clear source transaction failed"
        )
    }

    /// Adds a structural slot to both the canonical composition and the legacy
    /// compatibility mirror in one transaction. The artist action is preserved
    /// as a Decision; the Event remains the factual record of the structure edit.
    func addCanonicalSection(name: String, songID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let songIndex = catalog.songs.firstIndex(where: { $0.id == songID })
        else { return }

        let timestamp = Date()
        let sectionID = UUID()
        let legacySection = MasterSection(
            id: sectionID,
            name: trimmed,
            role: "Custom",
            assetID: nil,
            state: .open,
            confidence: 0,
            note: ""
        )
        let canonicalSection = MasterCompositionSection(
            id: sectionID,
            name: trimmed,
            role: "Custom",
            selections: [],
            state: .open,
            confidence: 0,
            note: ""
        )

        var updatedSong = catalog.songs[songIndex]
        updatedSong.sections.append(legacySection)
        recomputeMasterProgress(&updatedSong)
        updatedSong.updatedAt = timestamp

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: catalog.songs[songIndex])
        composition.sections.append(canonicalSection)
        composition.updatedAt = timestamp

        let event = CreativeEvent(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: .song,
            operation: .structureUpdated,
            beforeAssetID: nil,
            afterAssetID: nil,
            summary: "\(trimmed) slot added to master composition.",
            confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: .song,
            action: .approved,
            selectedAssetID: nil,
            rejectedAssetIDs: [],
            relatedEventIDs: [event.id],
            reason: "Added \(trimmed) to the current song structure.",
            source: .artist
        )

        commitMasterEdit(
            song: updatedSong,
            event: event,
            decision: decision,
            composition: composition,
            failureMessage: "Add master slot transaction failed"
        )
    }

    /// Removes a structural slot from canonical truth and the compatibility
    /// mirror atomically. Existing selections disappear from current intent but
    /// remain recoverable through immutable Assets, Events and Decision history.
    func removeCanonicalSection(sectionID: UUID, songID: UUID) {
        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == songID }) else { return }

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: catalog.songs[songIndex])
        guard let canonicalIndex = composition.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let removed = composition.sections[canonicalIndex]
        let legacySourceID = catalog.songs[songIndex].sections
            .first(where: { $0.id == sectionID })?
            .assetID

        let timestamp = Date()
        composition.sections.remove(at: canonicalIndex)
        composition.updatedAt = timestamp

        var updatedSong = catalog.songs[songIndex]
        updatedSong.sections.removeAll { $0.id == sectionID }
        recomputeMasterProgress(&updatedSong)
        updatedSong.updatedAt = timestamp

        var removedAssetIDs: [UUID] = []
        let canonicalSourceIDs = removed.selections.compactMap { selection -> UUID? in
            selection.kind == .sourceAsset ? selection.referenceID : nil
        }
        for id in canonicalSourceIDs + [legacySourceID].compactMap({ $0 }) where !removedAssetIDs.contains(id) {
            removedAssetIDs.append(id)
        }

        let event = CreativeEvent(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: .song,
            operation: .structureUpdated,
            beforeAssetID: removedAssetIDs.first,
            afterAssetID: nil,
            summary: "\(removed.name) slot removed from master composition.",
            confidence: 1
        )
        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: timestamp,
            target: .song,
            action: .reverted,
            selectedAssetID: nil,
            rejectedAssetIDs: removedAssetIDs,
            relatedEventIDs: [event.id],
            reason: "Removed \(removed.name) from the current song structure.",
            source: .artist
        )

        commitMasterEdit(
            song: updatedSong,
            event: event,
            decision: decision,
            composition: composition,
            failureMessage: "Remove master slot transaction failed"
        )
    }

    private func commitMasterEdit(
        song: Song,
        event: CreativeEvent,
        decision: CreativeDecision,
        composition: MasterComposition,
        failureMessage: String
    ) {
        do {
            try store.commitApproval(
                song: song,
                events: [event],
                decision: decision,
                masterComposition: composition
            )
        } catch {
            masterEditingLogger.error("\(failureMessage): \(error.localizedDescription)")
            return
        }

        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == song.id }) else { return }
        catalog.songs[songIndex] = song
        catalog.events.append(event)
        catalog.decisions.append(decision)
        catalog.setMasterComposition(composition)

        guard syncStatus == .on else { return }
        let changes = [
            SyncLogic.change(forSong: song),
            SyncLogic.change(forEvent: event),
            SyncLogic.change(forDecision: decision),
            SyncLogic.change(forMasterComposition: composition)
        ]
        scheduleCanonicalSync(changes)
    }

    private func recomputeMasterProgress(_ song: inout Song) {
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

    private func masterTarget(forSectionName name: String) -> EventTarget {
        let lower = name.lowercased()
        if lower.contains("intro") { return .intro }
        if lower.contains("verse") { return .verse }
        if lower.contains("hook") || lower.contains("chorus") { return .hook }
        if lower.contains("bridge") { return .bridge }
        return .song
    }
}
