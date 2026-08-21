import Foundation

/// Applies remote sync changes to an in-memory ArtistCatalog without I/O.
///
/// This is the shared application layer for macOS and iOS. It accepts both
/// legacy entities (Song / Asset / Event) and canonical Source-of-Truth
/// entities (CreativeDecision / MasterComposition), preserving LWW semantics
/// for mutable entities and identity semantics for immutable history.
public enum CanonicalSync {
    public struct AppliedChange: Equatable {
        public enum Kind: String, Equatable {
            case song, asset, event, decision, masterComposition
        }
        public var kind: Kind
        public var id: UUID
        public var deleted: Bool

        public init(kind: Kind, id: UUID, deleted: Bool) {
            self.kind = kind
            self.id = id
            self.deleted = deleted
        }
    }

    @discardableResult
    public static func apply(
        changes: [SyncLogic.JSONDict],
        to catalog: inout ArtistCatalog
    ) -> [AppliedChange] {
        var applied: [AppliedChange] = []

        for change in changes {
            guard let kindRaw = change["kind"] as? String,
                  let idString = change["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let updatedAtMs = (change["updatedAt"] as? NSNumber)?.doubleValue
            else { continue }

            let deleted = (change["deleted"] as? Bool) ?? false
            let remoteDate = SyncLogic.date(fromMs: updatedAtMs)
            let payload = change["data"] as? SyncLogic.JSONDict

            switch kindRaw {
            case SyncLogic.Kind.song.rawValue:
                let index = catalog.songs.firstIndex { $0.id == id }
                if deleted {
                    // Songs are permanent identity. Older clients may still emit
                    // destructive Song tombstones, so interpret them as a
                    // compatibility archive signal instead of deleting the Song
                    // and its immutable evidence/history. A tombstone for an
                    // unknown Song cannot safely reconstruct identity, so ignore it.
                    guard let index,
                          SyncLogic.shouldApplyRemote(
                            updatedAt: updatedAtMs,
                            overLocal: catalog.songs[index].updatedAt
                          )
                    else { continue }
                    catalog.songs[index] = SongLifecycle.archive(
                        catalog.songs[index],
                        at: remoteDate
                    )
                    applied.append(.init(kind: .song, id: id, deleted: false))
                    continue
                }
                guard SyncLogic.shouldApplyRemote(
                    updatedAt: updatedAtMs,
                    overLocal: index.map { catalog.songs[$0].updatedAt } ?? .distantPast
                ), let payload,
                      let merged = SyncLogic.mergedSong(
                        payload: payload,
                        updatedAt: remoteDate,
                        existing: index.map { catalog.songs[$0] }
                      )
                else { continue }
                if let index { catalog.songs[index] = merged } else { catalog.songs.append(merged) }
                applied.append(.init(kind: .song, id: id, deleted: false))

            case SyncLogic.Kind.asset.rawValue:
                let index = catalog.assets.firstIndex { $0.id == id }
                if deleted {
                    if let index { catalog.assets.remove(at: index) }
                    applied.append(.init(kind: .asset, id: id, deleted: true))
                    continue
                }
                guard SyncLogic.shouldApplyRemote(
                    updatedAt: updatedAtMs,
                    overLocal: index.map { catalog.assets[$0].updatedAt } ?? .distantPast
                ), let payload,
                      let merged = SyncLogic.mergedAsset(
                        payload: payload,
                        updatedAt: remoteDate,
                        existing: index.map { catalog.assets[$0] }
                      )
                else { continue }
                if let index { catalog.assets[index] = merged } else { catalog.assets.append(merged) }
                applied.append(.init(kind: .asset, id: id, deleted: false))

            case SyncLogic.Kind.event.rawValue:
                if deleted {
                    catalog.events.removeAll { $0.id == id }
                    applied.append(.init(kind: .event, id: id, deleted: true))
                    continue
                }
                guard !catalog.events.contains(where: { $0.id == id }), let payload,
                      let songIdString = payload["songId"] as? String,
                      let songID = UUID(uuidString: songIdString),
                      let targetRaw = payload["target"] as? String,
                      let target = EventTarget(rawValue: targetRaw),
                      let opRaw = payload["op"] as? String,
                      let operation = EventOperation(rawValue: opRaw),
                      let summary = payload["summary"] as? String
                else { continue }
                let confidence = (payload["confidence"] as? NSNumber)?.doubleValue ?? 1.0
                let before = (payload["beforeAssetId"] as? String).flatMap(UUID.init(uuidString:))
                let after = (payload["afterAssetId"] as? String).flatMap(UUID.init(uuidString:))
                catalog.events.append(CreativeEvent(
                    id: id,
                    songID: songID,
                    timestamp: remoteDate,
                    target: target,
                    operation: operation,
                    beforeAssetID: before,
                    afterAssetID: after,
                    summary: summary,
                    confidence: confidence
                ))
                applied.append(.init(kind: .event, id: id, deleted: false))

            case SyncLogic.decisionKind:
                if deleted {
                    catalog.decisions.removeAll { $0.id == id }
                    applied.append(.init(kind: .decision, id: id, deleted: true))
                    continue
                }
                guard let payload,
                      let remote = SyncLogic.decision(payload: payload, updatedAt: remoteDate)
                else { continue }
                if let index = catalog.decisions.firstIndex(where: { $0.id == id }) {
                    guard remote.timestamp > catalog.decisions[index].timestamp else { continue }
                    catalog.decisions[index] = remote
                } else {
                    catalog.decisions.append(remote)
                }
                applied.append(.init(kind: .decision, id: id, deleted: false))

            case SyncLogic.masterCompositionKind:
                if deleted {
                    if let existing = catalog.masterCompositions.first(where: { $0.id == id }) {
                        catalog.removeMasterComposition(for: existing.songID)
                    }
                    applied.append(.init(kind: .masterComposition, id: id, deleted: true))
                    continue
                }
                guard let payload,
                      let remote = SyncLogic.masterComposition(payload: payload, updatedAt: remoteDate)
                else { continue }
                let local = catalog.masterCompositions.first { $0.songID == remote.songID }
                guard local == nil || remote.updatedAt > local!.updatedAt else { continue }
                catalog.setMasterComposition(remote)
                applied.append(.init(kind: .masterComposition, id: id, deleted: false))

            default:
                continue
            }
        }

        return applied
    }
}
