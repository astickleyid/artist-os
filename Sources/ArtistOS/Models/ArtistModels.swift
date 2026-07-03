import Foundation

struct ArtistCatalog: Codable, Equatable {
    var artistName: String
    var songs: [Song]
    var assets: [Asset]
    var events: [CreativeEvent]
}

struct Song: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var era: String
    var status: SongStatus
    var progress: Double
    var qualityScore: Double
    var risk: String
    var sections: [MasterSection]
}

enum SongStatus: String, Codable, CaseIterable {
    case assembling = "In Assembly"
    case review = "Review"
    case queue = "Queue"
    case archived = "Archived"
}

struct MasterSection: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var role: String
    var assetID: UUID?
    var state: SectionState
    var confidence: Double
    var note: String
}

enum SectionState: String, Codable, CaseIterable {
    case locked = "Locked"
    case candidate = "Candidate"
    case needsDecision = "Needs Decision"
    case experiment = "Experiment"
    case open = "Open"
}

struct Asset: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var originalFilename: String
    var role: AssetRole
    var createdAt: Date
    var duration: TimeInterval?
    var localURLBookmark: Data?
    var songID: UUID? = nil
    var sourcePath: String? = nil
    var fileSize: Int64? = nil
    var format: String? = nil
    var sampleRate: Double? = nil
    var channels: Int? = nil
    var contentHash: String? = nil
}

struct WatchedFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var path: String
    var bookmark: Data?
    var addedAt: Date

    var displayName: String {
        (path as NSString).lastPathComponent
    }
}

enum AssetRole: String, Codable, CaseIterable {
    case fullMix = "Full Mix"
    case leadVocal = "Lead Vocal"
    case beat = "Beat"
    case hook = "Hook"
    case bridge = "Bridge"
    case reference = "Reference"
}

struct CreativeEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var songID: UUID
    var timestamp: Date
    var target: EventTarget
    var operation: EventOperation
    var beforeAssetID: UUID?
    var afterAssetID: UUID?
    var summary: String
    var confidence: Double
}

enum EventTarget: String, Codable, CaseIterable {
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

enum EventOperation: String, Codable, CaseIterable {
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
