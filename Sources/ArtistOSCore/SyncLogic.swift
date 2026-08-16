import Foundation

/// Cloudflare sync — pure logic (encoding, conflict resolution) mirroring
/// docs/sync.js per VISION.md. Uses plain JSON-compatible dictionaries
/// (not strict Codable round-tripping) because the wire contract is shared
/// with an independently-evolving JS worker and web client: dictionary
/// access degrades gracefully when either side adds/omits a field, where
/// strict Decodable would fail the whole payload. Zero I/O — testable directly.
public enum SyncLogic {

    public typealias JSONDict = [String: Any]

    /// Legacy kinds currently consumed by the existing macOS/iOS/web application
    /// loops. Canonical kinds are exposed separately so the wire contract can
    /// land without making every legacy switch non-exhaustive in the same commit.
    public enum Kind: String { case song, asset, event }
    public static let decisionKind = "decision"
    public static let masterCompositionKind = "masterComposition"

    // MARK: - Encoding (entity -> wire dictionary)

    private static func msSince1970(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    public static func dict(fromSection section: MasterSection) -> JSONDict {
        [
            "id": section.id.uuidString, "name": section.name, "role": section.role,
            "assetID": section.assetID?.uuidString as Any, "state": section.state.rawValue,
            "confidence": section.confidence, "note": section.note
        ]
    }

    public static func songPayload(_ song: Song) -> JSONDict {
        [
            "id": song.id.uuidString, "title": song.title, "era": song.era,
            "status": song.status.rawValue, "progress": song.progress,
            "qualityScore": song.qualityScore, "risk": song.risk,
            "masterAssetId": song.masterAssetID?.uuidString as Any,
            "sections": song.sections.map(dict(fromSection:))
        ]
    }

    public static func assetPayload(_ asset: Asset) -> JSONDict {
        [
            "id": asset.id.uuidString, "songId": asset.songID?.uuidString as Any,
            "title": asset.title, "file": asset.originalFilename, "role": asset.role.rawValue,
            "version": asset.version as Any, "vOrder": asset.vOrder as Any,
            "bpm": asset.bpm as Any, "keyName": asset.musicalKey as Any,
            "hash": asset.contentHash as Any, "cloudKey": asset.cloudKey as Any
        ]
    }

    /// Events are facts. The wire payload preserves before/after asset linkage so
    /// a remote device receives the same evidence graph as the originating Mac.
    public static func eventPayload(_ event: CreativeEvent) -> JSONDict {
        [
            "id": event.id.uuidString, "songId": event.songID.uuidString,
            "target": event.target.rawValue, "op": event.operation.rawValue,
            "beforeAssetId": event.beforeAssetID?.uuidString as Any,
            "afterAssetId": event.afterAssetID?.uuidString as Any,
            "summary": event.summary, "confidence": event.confidence
        ]
    }

    public static func decisionPayload(_ decision: CreativeDecision) -> JSONDict {
        [
            "id": decision.id.uuidString,
            "songId": decision.songID.uuidString,
            "target": decision.target.rawValue,
            "action": decision.action.rawValue,
            "selectedAssetId": decision.selectedAssetID?.uuidString as Any,
            "rejectedAssetIds": decision.rejectedAssetIDs.map(\.uuidString),
            "relatedEventIds": decision.relatedEventIDs.map(\.uuidString),
            "reason": decision.reason as Any,
            "source": decision.source.rawValue
        ]
    }

    public static func dict(from selection: MasterSelection) -> JSONDict {
        [
            "id": selection.id.uuidString,
            "kind": selection.kind.rawValue,
            "referenceId": selection.referenceID.uuidString,
            "decisionId": selection.decisionID?.uuidString as Any,
            "selectedAt": msSince1970(selection.selectedAt)
        ]
    }

    public static func dict(from section: MasterCompositionSection) -> JSONDict {
        [
            "id": section.id.uuidString,
            "name": section.name,
            "role": section.role,
            "selections": section.selections.map(dict(from:)),
            "state": section.state.rawValue,
            "confidence": section.confidence,
            "note": section.note
        ]
    }

    public static func masterCompositionPayload(_ composition: MasterComposition) -> JSONDict {
        [
            "id": composition.id.uuidString,
            "songId": composition.songID.uuidString,
            "sections": composition.sections.map(dict(from:)),
            "outputAssetId": composition.outputAssetID?.uuidString as Any
        ]
    }

    public static func change(kind: Kind, id: String, updatedAt: Date, data: JSONDict) -> JSONDict {
        change(kindRaw: kind.rawValue, id: id, updatedAt: updatedAt, data: data)
    }

    public static func change(kindRaw: String, id: String, updatedAt: Date, data: JSONDict) -> JSONDict {
        ["kind": kindRaw, "id": id, "updatedAt": msSince1970(updatedAt), "data": data]
    }

    public static func change(forSong song: Song) -> JSONDict {
        change(kind: .song, id: song.id.uuidString, updatedAt: song.updatedAt, data: songPayload(song))
    }
    public static func change(forAsset asset: Asset) -> JSONDict {
        change(kind: .asset, id: asset.id.uuidString, updatedAt: asset.updatedAt, data: assetPayload(asset))
    }
    public static func change(forEvent event: CreativeEvent) -> JSONDict {
        change(kind: .event, id: event.id.uuidString, updatedAt: event.timestamp, data: eventPayload(event))
    }
    public static func change(forDecision decision: CreativeDecision) -> JSONDict {
        change(kindRaw: decisionKind, id: decision.id.uuidString,
               updatedAt: decision.timestamp, data: decisionPayload(decision))
    }
    public static func change(forMasterComposition composition: MasterComposition) -> JSONDict {
        change(kindRaw: masterCompositionKind, id: composition.id.uuidString,
               updatedAt: composition.updatedAt, data: masterCompositionPayload(composition))
    }

    public static func tombstone(kind: Kind, id: String) -> JSONDict {
        tombstone(kindRaw: kind.rawValue, id: id)
    }

    public static func tombstone(kindRaw: String, id: String) -> JSONDict {
        ["kind": kindRaw, "id": id, "updatedAt": msSince1970(Date()), "deleted": true]
    }

    // MARK: - Decoding (wire dictionary -> entity), used when pulling remote changes

    private static func uuid(_ dict: JSONDict, _ key: String) -> UUID? {
        (dict[key] as? String).flatMap(UUID.init(uuidString:))
    }
    private static func string(_ dict: JSONDict, _ key: String) -> String? { dict[key] as? String }
    private static func double(_ dict: JSONDict, _ key: String) -> Double? {
        (dict[key] as? Double) ?? (dict[key] as? NSNumber)?.doubleValue
    }
    private static func int(_ dict: JSONDict, _ key: String) -> Int? {
        (dict[key] as? Int) ?? (dict[key] as? NSNumber)?.intValue
    }
    private static func uuidArray(_ dict: JSONDict, _ key: String) -> [UUID] {
        (dict[key] as? [String] ?? []).compactMap(UUID.init(uuidString:))
    }

    public static func section(from dict: JSONDict) -> MasterSection? {
        guard let id = uuid(dict, "id"), let name = string(dict, "name"),
              let role = string(dict, "role"),
              let stateRaw = string(dict, "state"), let state = SectionState(rawValue: stateRaw)
        else { return nil }
        return MasterSection(
            id: id, name: name, role: role,
            assetID: uuid(dict, "assetID"), state: state,
            confidence: double(dict, "confidence") ?? 0,
            note: string(dict, "note") ?? ""
        )
    }

    public static func mergedSong(payload: JSONDict, updatedAt: Date, existing: Song?) -> Song? {
        guard let idString = string(payload, "id"), let id = UUID(uuidString: idString) else { return nil }
        var song = existing ?? Song(
            id: id, title: "", era: "", status: .assembling, progress: 0,
            qualityScore: 0, risk: "low", sections: []
        )
        if let v = string(payload, "title") { song.title = v }
        if let v = string(payload, "era") { song.era = v }
        if let v = string(payload, "status"), let status = SongStatus(rawValue: v) { song.status = status }
        if let v = double(payload, "progress") { song.progress = v }
        if let v = double(payload, "qualityScore") { song.qualityScore = v }
        if let v = string(payload, "risk") { song.risk = v }
        song.masterAssetID = uuid(payload, "masterAssetId")
        if let sectionDicts = payload["sections"] as? [JSONDict] {
            song.sections = sectionDicts.compactMap(section(from:))
        }
        song.updatedAt = updatedAt
        return song
    }

    public static func mergedAsset(payload: JSONDict, updatedAt: Date, existing: Asset?) -> Asset? {
        guard let idString = string(payload, "id"), let id = UUID(uuidString: idString) else { return nil }
        var asset = existing ?? Asset(
            id: id, title: "", originalFilename: "", role: .fullMix,
            createdAt: Date(), duration: nil, localURLBookmark: nil
        )
        asset.songID = uuid(payload, "songId")
        if let v = string(payload, "title") { asset.title = v }
        if let v = string(payload, "file") { asset.originalFilename = v }
        if let v = string(payload, "role"), let role = AssetRole(rawValue: v) { asset.role = role }
        asset.version = string(payload, "version")
        asset.vOrder = int(payload, "vOrder")
        asset.bpm = double(payload, "bpm")
        asset.musicalKey = string(payload, "keyName")
        asset.contentHash = string(payload, "hash")
        asset.cloudKey = string(payload, "cloudKey")
        asset.updatedAt = updatedAt
        return asset
    }

    public static func decision(payload: JSONDict, updatedAt: Date) -> CreativeDecision? {
        guard let id = uuid(payload, "id"),
              let songID = uuid(payload, "songId"),
              let targetRaw = string(payload, "target"), let target = EventTarget(rawValue: targetRaw),
              let actionRaw = string(payload, "action"), let action = DecisionAction(rawValue: actionRaw),
              let sourceRaw = string(payload, "source"), let source = DecisionSource(rawValue: sourceRaw)
        else { return nil }
        return CreativeDecision(
            id: id,
            songID: songID,
            timestamp: updatedAt,
            target: target,
            action: action,
            selectedAssetID: uuid(payload, "selectedAssetId"),
            rejectedAssetIDs: uuidArray(payload, "rejectedAssetIds"),
            relatedEventIDs: uuidArray(payload, "relatedEventIds"),
            reason: string(payload, "reason"),
            source: source
        )
    }

    public static func masterSelection(from dict: JSONDict) -> MasterSelection? {
        guard let id = uuid(dict, "id"),
              let kindRaw = string(dict, "kind"), let kind = MasterSelectionKind(rawValue: kindRaw),
              let referenceID = uuid(dict, "referenceId"),
              let selectedAtMs = double(dict, "selectedAt")
        else { return nil }
        return MasterSelection(
            id: id,
            kind: kind,
            referenceID: referenceID,
            decisionID: uuid(dict, "decisionId"),
            selectedAt: date(fromMs: selectedAtMs)
        )
    }

    public static func masterCompositionSection(from dict: JSONDict) -> MasterCompositionSection? {
        guard let id = uuid(dict, "id"),
              let name = string(dict, "name"),
              let role = string(dict, "role"),
              let stateRaw = string(dict, "state"), let state = SectionState(rawValue: stateRaw)
        else { return nil }
        let selections = (dict["selections"] as? [JSONDict] ?? []).compactMap(masterSelection(from:))
        return MasterCompositionSection(
            id: id,
            name: name,
            role: role,
            selections: selections,
            state: state,
            confidence: double(dict, "confidence") ?? 0,
            note: string(dict, "note") ?? ""
        )
    }

    public static func masterComposition(payload: JSONDict, updatedAt: Date) -> MasterComposition? {
        guard let id = uuid(payload, "id"), let songID = uuid(payload, "songId") else { return nil }
        let sections = (payload["sections"] as? [JSONDict] ?? []).compactMap(masterCompositionSection(from:))
        return MasterComposition(
            id: id,
            songID: songID,
            sections: sections,
            outputAssetID: uuid(payload, "outputAssetId"),
            updatedAt: updatedAt
        )
    }

    // MARK: - Conflict resolution

    public static func shouldApplyRemote(updatedAt remoteMs: Double, overLocal localDate: Date) -> Bool {
        remoteMs > msSince1970(localDate)
    }

    public static func date(fromMs ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
