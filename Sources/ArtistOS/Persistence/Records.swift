import Foundation
import GRDB

// Flat record types keep the SQLite schema decoupled from the domain models.
// Enums are stored as raw strings for forward-compatible decoding.

struct SongRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "song"
    var id: UUID
    var title: String
    var era: String
    var status: String
    var progress: Double
    var qualityScore: Double
    var risk: String
    var masterAssetID: UUID?
    var updatedAt: Date

    init(_ song: Song) {
        id = song.id
        title = song.title
        era = song.era
        status = song.status.rawValue
        progress = song.progress
        qualityScore = song.qualityScore
        risk = song.risk
        masterAssetID = song.masterAssetID
        updatedAt = song.updatedAt
    }

    func toDomain(sections: [MasterSection]) -> Song {
        Song(
            id: id,
            title: title,
            era: era,
            status: SongStatus(rawValue: status) ?? .assembling,
            progress: progress,
            qualityScore: qualityScore,
            risk: risk,
            sections: sections,
            masterAssetID: masterAssetID,
            updatedAt: updatedAt
        )
    }
}

struct SectionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "section"
    var id: UUID
    var songID: UUID
    var position: Int
    var name: String
    var role: String
    var assetID: UUID?
    var state: String
    var confidence: Double
    var note: String

    init(_ section: MasterSection, songID: UUID, position: Int) {
        id = section.id
        self.songID = songID
        self.position = position
        name = section.name
        role = section.role
        assetID = section.assetID
        state = section.state.rawValue
        confidence = section.confidence
        note = section.note
    }

    func toDomain() -> MasterSection {
        MasterSection(
            id: id,
            name: name,
            role: role,
            assetID: assetID,
            state: SectionState(rawValue: state) ?? .open,
            confidence: confidence,
            note: note
        )
    }
}

struct AssetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "asset"
    var id: UUID
    var songID: UUID?
    var title: String
    var originalFilename: String
    var role: String
    var createdAt: Date
    var duration: Double?
    var localURLBookmark: Data?
    var sourcePath: String?
    var fileSize: Int64?
    var format: String?
    var sampleRate: Double?
    var channels: Int?
    var contentHash: String?
    var fileModifiedAt: Date?
    var version: String?
    var vOrder: Int?
    var bpm: Double?
    var musicalKey: String?
    var analyzedAt: Date?
    var updatedAt: Date
    var cloudKey: String?

    init(_ asset: Asset) {
        id = asset.id
        songID = asset.songID
        title = asset.title
        originalFilename = asset.originalFilename
        role = asset.role.rawValue
        createdAt = asset.createdAt
        duration = asset.duration
        localURLBookmark = asset.localURLBookmark
        sourcePath = asset.sourcePath
        fileSize = asset.fileSize
        format = asset.format
        sampleRate = asset.sampleRate
        channels = asset.channels
        contentHash = asset.contentHash
        fileModifiedAt = asset.fileModifiedAt
        version = asset.version
        vOrder = asset.vOrder
        bpm = asset.bpm
        musicalKey = asset.musicalKey
        analyzedAt = asset.analyzedAt
        updatedAt = asset.updatedAt
        cloudKey = asset.cloudKey
    }

    func toDomain() -> Asset {
        Asset(
            id: id,
            title: title,
            originalFilename: originalFilename,
            role: AssetRole(rawValue: role) ?? .fullMix,
            createdAt: createdAt,
            duration: duration,
            localURLBookmark: localURLBookmark,
            songID: songID,
            sourcePath: sourcePath,
            fileSize: fileSize,
            format: format,
            sampleRate: sampleRate,
            channels: channels,
            contentHash: contentHash,
            fileModifiedAt: fileModifiedAt,
            version: version,
            vOrder: vOrder,
            bpm: bpm,
            musicalKey: musicalKey,
            analyzedAt: analyzedAt,
            updatedAt: updatedAt,
            cloudKey: cloudKey
        )
    }
}

struct WatchedFolderRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "watchedFolder"
    var id: UUID
    var path: String
    var bookmark: Data?
    var addedAt: Date

    init(_ folder: WatchedFolder) {
        id = folder.id
        path = folder.path
        bookmark = folder.bookmark
        addedAt = folder.addedAt
    }

    func toDomain() -> WatchedFolder {
        WatchedFolder(id: id, path: path, bookmark: bookmark, addedAt: addedAt)
    }
}

struct EventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "event"
    var id: UUID
    var songID: UUID
    var timestamp: Date
    var target: String
    var operation: String
    var beforeAssetID: UUID?
    var afterAssetID: UUID?
    var summary: String
    var confidence: Double

    init(_ event: CreativeEvent) {
        id = event.id
        songID = event.songID
        timestamp = event.timestamp
        target = event.target.rawValue
        operation = event.operation.rawValue
        beforeAssetID = event.beforeAssetID
        afterAssetID = event.afterAssetID
        summary = event.summary
        confidence = event.confidence
    }

    func toDomain() -> CreativeEvent {
        CreativeEvent(
            id: id,
            songID: songID,
            timestamp: timestamp,
            target: EventTarget(rawValue: target) ?? .song,
            operation: EventOperation(rawValue: operation) ?? .structureUpdated,
            beforeAssetID: beforeAssetID,
            afterAssetID: afterAssetID,
            summary: summary,
            confidence: confidence
        )
    }
}
