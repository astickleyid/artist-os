import Foundation
import ArtistOSCore

@MainActor
extension AppState {
    /// Sends one logical canonical edit as a single batch and retries transient
    /// failures while the app remains open. Local catalog truth is already
    /// persisted before this method is called; sync failure must never roll it back.
    @discardableResult
    func pushCanonicalChangesWithRetry(
        _ changes: [SyncLogic.JSONDict],
        retryDelaysNanoseconds: [UInt64] = [0, 1_500_000_000, 5_000_000_000]
    ) async -> Bool {
        guard syncStatus == .on, !changes.isEmpty else { return false }

        let delays = retryDelaysNanoseconds.isEmpty ? [UInt64(0)] : retryDelaysNanoseconds
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return false }
            }
            guard !Task.isCancelled else { return false }

            do {
                _ = try await sync.push(changes: changes)
                syncLastError = nil
                return true
            } catch {
                syncLastError = error.localizedDescription
                let hasAnotherAttempt = attempt < delays.count - 1
                guard hasAnotherAttempt, isRetryableCanonicalSyncError(error) else { return false }
            }
        }
        return false
    }

    /// Persists canonical delivery intent before starting network work. The outbox
    /// is coalesced by kind:id in GRDB, so a process crash cannot silently discard
    /// the latest unsent Decision or Master Composition change.
    func scheduleCanonicalSync(_ changes: [SyncLogic.JSONDict]) {
        guard syncStatus == .on, !changes.isEmpty else { return }
        do {
            try store.enqueueCanonicalSyncChanges(changes)
        } catch {
            syncLastError = "Failed to persist sync outbox: \(error.localizedDescription)"
            return
        }
        resumeCanonicalSyncOutbox()
    }

    /// Safe to call repeatedly. Duplicate sends are acceptable because the server
    /// resolves the same kind:id by updatedAt; rows are removed only after an
    /// acknowledged successful push.
    func resumeCanonicalSyncOutbox() {
        guard syncStatus == .on else { return }
        Task { [weak self] in
            await self?.drainCanonicalSyncOutbox()
        }
    }

    func drainCanonicalSyncOutbox(
        retryDelaysNanoseconds: [UInt64] = [0, 1_500_000_000, 5_000_000_000]
    ) async {
        guard syncStatus == .on else { return }
        let pending: [CanonicalSyncOutboxItem]
        do {
            pending = try store.canonicalSyncOutbox()
        } catch {
            syncLastError = "Failed to read sync outbox: \(error.localizedDescription)"
            return
        }
        guard !pending.isEmpty else { return }

        let didPush = await pushCanonicalChangesWithRetry(
            pending.map(\.change),
            retryDelaysNanoseconds: retryDelaysNanoseconds
        )
        guard didPush else { return }

        do {
            // Delete only the exact payloads acknowledged by this push. If a newer
            // edit replaced the same kind:id while the request was in flight, its
            // different payload remains queued for the next drain.
            try store.removeCanonicalSyncOutbox(pending)
        } catch {
            syncLastError = "Cloud accepted changes, but local outbox cleanup failed: \(error.localizedDescription)"
        }
    }

    private func isRetryableCanonicalSyncError(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let syncError = error as? SyncError else { return false }
        switch syncError {
        case .server(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .invalidResponse, .malformedBody, .notEnabled:
            return false
        }
    }
}
