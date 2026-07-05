import Foundation

// Domain models — the shared truth across macOS, iOS, and sync.
// Public with EXPLICIT public initializers: Swift memberwise inits are
// internal-only, so every init here mirrors the memberwise shape (with the
// same defaults) to keep all existing call sites working across modules.

public struct ArtistCatalog: Codable, Equatable {
    public var artistName: String
    public var songs: [Song]
    public var assets: [Asset]
    public var events: [CreativeEvent]
    public init(artistName: String, songs: [Song], assets: [Asset], events: [CreativeEvent]) {
        self.artistName = artistName; self.songs = songs; self.assets = assets; self.events = events
    }
}

public struct Song: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var era: String
    public var status: SongStatus
    public var progress: Double
    public var qualityScore: Double
    public var risk: String
    public var sections: [MasterSection]
    public var masterAssetID: UUID?
    public var updatedAt: Date
    public init(id: UUID, title: String, era: String, status: SongStatus, progress: Double,
                qualityScore: Double, risk: String, sections: [MasterSection],
                masterAssetID: UUID? = nil, updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.era = era; self.status = status
        self.progress = progress; self.qualityScore = qualityScore; self.risk = risk
        self.sections = sections; self.masterAssetID = masterAssetID; self.updatedAt = updatedAt
    }
}

public enum SongStatus: String, Codable, CaseIterable {
    case assembling = "In Assembly"
    case review = "Review"
    case queue = "Queue"
    case archived = "Archived"
}

public struct MasterSection: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var role: String
    public var assetID: UUID?
    public var state: SectionState
    public var confidence: Double
    public var note: String
    public init(id: UUID, name: String, role: String, assetID: UUID?, state: SectionState,
                confidence: Double, note: String) {
        self.id = id; self.name = name; self.role = role; self.assetID = assetID
        self.state = state; self.confidence = confidence; self.note = note
    }
}

public enum SectionState: String, Codable, CaseIterable {
    case locked = "Locked"
    case candidate = "Candidate"
    case needsDecision = "Needs Decision"
    case experiment = "Experiment"
    case open = "Open"
}

public struct Asset: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var originalFilename: String
    public var role: AssetRole
    public var createdAt: Date
    public var duration: TimeInterval?
    public var localURLBookmark: Data?
    public var songID: UUID?
    public var sourcePath: String?
    public var fileSize: Int64?
    public var format: String?
    public var sampleRate: Double?
    public var channels: Int?
    public var contentHash: String?
    public var fileModifiedAt: Date?
    public var version: String?
    public var vOrder: Int?
    public var bpm: Double?
    public var musicalKey: String?
    public var analyzedAt: Date?
    public var updatedAt: Date
    public var cloudKey: String?
    public init(id: UUID, title: String, originalFilename: String, role: AssetRole, createdAt: Date,
                duration: TimeInterval?, localURLBookmark: Data?, songID: UUID? = nil,
                sourcePath: String? = nil, fileSize: Int64? = nil, format: String? = nil,
                sampleRate: Double? = nil, channels: Int? = nil, contentHash: String? = nil,
                fileModifiedAt: Date? = nil, version: String? = nil, vOrder: Int? = nil,
                bpm: Double? = nil, musicalKey: String? = nil, analyzedAt: Date? = nil,
                updatedAt: Date = Date(), cloudKey: String? = nil) {
        self.id = id; self.title = title; self.originalFilename = originalFilename; self.role = role
        self.createdAt = createdAt; self.duration = duration; self.localURLBookmark = localURLBookmark
        self.songID = songID; self.sourcePath = sourcePath; self.fileSize = fileSize; self.format = format
        self.sampleRate = sampleRate; self.channels = channels; self.contentHash = contentHash
        self.fileModifiedAt = fileModifiedAt; self.version = version; self.vOrder = vOrder
        self.bpm = bpm; self.musicalKey = musicalKey; self.analyzedAt = analyzedAt
        self.updatedAt = updatedAt; self.cloudKey = cloudKey
    }
}

public enum AssetRole: String, Codable, CaseIterable {
    case fullMix = "Full Mix"
    case leadVocal = "Lead Vocal"
    case beat = "Beat"
    case hook = "Hook"
    case bridge = "Bridge"
    case reference = "Reference"
}

public struct CreativeEvent: Identifiable, Codable, Equatable {
    public var id: UUID
    public var songID: UUID
    public var timestamp: Date
    public var target: EventTarget
    public var operation: EventOperation
    public var beforeAssetID: UUID?
    public var afterAssetID: UUID?
    public var summary: String
    public var confidence: Double
    public init(id: UUID, songID: UUID, timestamp: Date, target: EventTarget, operation: EventOperation,
                beforeAssetID: UUID?, afterAssetID: UUID?, summary: String, confidence: Double) {
        self.id = id; self.songID = songID; self.timestamp = timestamp; self.target = target
        self.operation = operation; self.beforeAssetID = beforeAssetID; self.afterAssetID = afterAssetID
        self.summary = summary; self.confidence = confidence
    }
}

public enum EventTarget: String, Codable, CaseIterable {
    case song = "Song"
    case intro = "Intro"
    case verse = "Verse"
    case hook = "Hook"
    case bridge = "Bridge"
    case leadVocal = "Lead Vocal"
    case beat = "Beat"
    case mix = "Mix"
    case master = "Master"
}

public enum EventOperation: String, Codable, CaseIterable {
    case imported = "Imported"
    case sourceSelected = "Source Selected"
    case candidateAdded = "Candidate Added"
    case recordingUpdated = "Recording Updated"
    case processingUpdated = "Processing Updated"
    case structureUpdated = "Structure Updated"
    case needsDecision = "Needs Decision"
    case approved = "Approved"
    case archived = "Archived"
}
