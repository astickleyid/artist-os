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

        do {
            try store.commitApproval(
                song: updatedSong,
                events: [event],
                decision: decision,
                masterComposition: composition
            )
        } catch {
            masterEditingLogger.error("Clear source transaction failed: \(error.localizedDescription)")
            return
        }

        catalog.songs[songIndex] = updatedSong
        catalog.events.append(event)
        catalog.decisions.append(decision)
        catalog.setMasterComposition(composition)

        guard syncStatus == .on else { return }
        let changes = [
            SyncLogic.change(forSong: updatedSong),
            SyncLogic.change(forEvent: event),
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
