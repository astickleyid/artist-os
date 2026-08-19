import Foundation
import ArtistOSCore

@MainActor
extension AppState {
    /// Sends one logical canonical edit as a single batch and retries transient
    /// failures while the app remains open. Local catalog truth is already
    /// persisted before this method is called; sync failure must never roll it back.
    ///
    /// This is intentionally shared by approval, structure/state, and annotation
    /// flows so Song / Event / Decision / Master Composition never get different
    /// retry behavior merely because they originated from a different screen.
    @discardableResult
    func pushCanonicalChangesWithRetry(
        _ changes: [SyncLogic.JSONDict],
        retryDelaysNanoseconds: [UInt64] = [0, 1_500_000_000, 5_000_000_000]
    ) async -> Bool {
        guard syncStatus == .on, !changes.isEmpty else { return false }

        let delays = retryDelaysNanoseconds.isEmpty ? [UInt64(0)] : retryDelaysNanoseconds
        for delay in delays {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return false
                }
            }
            guard !Task.isCancelled else { return false }

            do {
                _ = try await sync.push(changes: changes)
                syncLastError = nil
                return true
            } catch {
                syncLastError = error.localizedDescription
            }
        }
        return false
    }

    /// Fire-and-forget UI boundary for canonical edits. The retry loop itself is
    /// async and testable; callers do not block the artist's editing interaction.
    func scheduleCanonicalSync(_ changes: [SyncLogic.JSONDict]) {
        guard syncStatus == .on, !changes.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.pushCanonicalChangesWithRetry(changes)
        }
    }
}
