import Foundation

/// Cloudflare sync — pure logic (encoding, conflict resolution) mirroring
/// docs/sync.js per VISION.md. Uses plain JSON-compatible dictionaries
/// (not strict Codable round-tripping) because the wire contract is shared
/// with an independently-evolving JS worker and web client: dictionary
/// access degrades gracefully when either side adds/omits a field, where
/// strict Decodable would fail the whole payload. Zero I/O — testable directly.
public enum SyncLogic {

    public typealias JSONDict = [String: Any]

    public enum Kind: String { case song, asset, event }

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

    /// Note: unlike the web model, CreativeEvent has no boolean "observed"
    /// flag — observed-ness is conveyed in summary text by convention.
    /// This is a known, harmless platform divergence (tracked in VISION.md).
    public static func eventPayload(_ event: CreativeEvent) -> JSONDict {
        [
            "id": event.id.uuidString, "songId": event.songID.uuidString,
            "target": event.target.rawValue, "op": event.operation.rawValue,
            "summary": event.summary, "confidence": event.confidence
        ]
    }

    public static func change(kind: Kind, id: String, updatedAt: Date, data: JSONDict) -> JSONDict {
        ["kind": kind.rawValue, "id": id, "updatedAt": msSince1970(updatedAt), "data": data]
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

    public static func tombstone(kind: Kind, id: String) -> JSONDict {
        ["kind": kind.rawValue, "id": id, "updatedAt": msSince1970(Date()), "deleted": true]
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

    /// Merges a remote song payload into an existing local song (if any),
    /// preserving fields the wire contract doesn't carry (defensive against
    /// future divergence) while applying every field it does carry.
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

    // MARK: - Conflict resolution
    // Mirrors applyRemoteChange in docs/sync.js: a remote change only wins
    // when it's strictly newer. A tie means "we just wrote this locally in
    // the same instant" and local wins.

    public static func shouldApplyRemote(updatedAt remoteMs: Double, overLocal localDate: Date) -> Bool {
        remoteMs > msSince1970(localDate)
    }

    public static func date(fromMs ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
