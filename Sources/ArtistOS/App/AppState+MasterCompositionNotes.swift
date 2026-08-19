import Foundation
import ArtistOSCore
import os

private let masterNotesLogger = Logger(
    subsystem: "com.stickley.artistos",
    category: "MasterCompositionNotes"
)

@MainActor
extension AppState {
    /// Notes are annotations rather than Creative Decisions. Keep the canonical
    /// Master Composition and legacy Song mirror aligned atomically during the
    /// migration without polluting factual Event or intent Decision history.
    func updateCanonicalSectionNote(_ note: String, sectionID: UUID, songID: UUID) {
        guard let songIndex = catalog.songs.firstIndex(where: { $0.id == songID }) else { return }

        var composition = catalog.masterCompositions.first(where: { $0.songID == songID })
            ?? MasterComposition.projected(from: catalog.songs[songIndex])
        guard let compositionSectionIndex = composition.sections.firstIndex(where: { $0.id == sectionID })
        else { return }

        let legacySectionIndex = catalog.songs[songIndex].sections.firstIndex { $0.id == sectionID }
        let currentCanonicalNote = composition.sections[compositionSectionIndex].note
        let currentLegacyNote = legacySectionIndex.map { catalog.songs[songIndex].sections[$0].note }
        guard currentCanonicalNote != note || currentLegacyNote != note else { return }

        let timestamp = Date()
        composition.sections[compositionSectionIndex].note = note
        composition.updatedAt = timestamp

        var updatedSong = catalog.songs[songIndex]
        if let legacySectionIndex {
            updatedSong.sections[legacySectionIndex].note = note
        }
        updatedSong.updatedAt = timestamp

        do {
            try store.commitMasterAnnotation(
                song: updatedSong,
                masterComposition: composition
            )
        } catch {
            masterNotesLogger.error("Master note transaction failed: \(error.localizedDescription)")
            return
        }

        catalog.songs[songIndex] = updatedSong
        catalog.setMasterComposition(composition)

        guard syncStatus == .on else { return }
        let changes = [
            SyncLogic.change(forSong: updatedSong),
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
}