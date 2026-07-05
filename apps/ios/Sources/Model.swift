import Foundation
import ArtistOSCore

// TEMPORARY view layer. These lightweight types drive the Home UI so the design
// is real and reviewable now. They will be REPLACED by the shared ArtistOSCore
// domain models (Song, Asset, CreativeEvent, decisions) once those are made
// public + moved into the core library and the live sync client is wired in.
// Keeping them isolated here means that swap touches only this file.

struct MobileSong: Identifiable, Equatable {
    let id: String
    var title: String
    var status: String
    var versionCount: Int
    var lastTouch: Date
    var bpm: Int?
    var key: String?
}

struct MobileDecision: Identifiable, Equatable {
    enum Kind { case competing, master }
    let id: String
    var kind: Kind
    var songTitle: String
    var detail: String
}

struct MobileEvent: Identifiable, Equatable {
    let id: String
    var summary: String
    var songTitle: String?
    var at: Date
}

@MainActor
final class MobileStore: ObservableObject {
    @Published var songs: [MobileSong]
    @Published var decisions: [MobileDecision]
    @Published var recent: [MobileEvent]

    init() {
        let now = Date()
        songs = [
            MobileSong(id: "s1", title: "Night Drive", status: "In assembly", versionCount: 6, lastTouch: now.addingTimeInterval(-3600), bpm: 120, key: "A minor"),
            MobileSong(id: "s2", title: "Golden State", status: "Mixing", versionCount: 4, lastTouch: now.addingTimeInterval(-7200), bpm: 92, key: "G major"),
            MobileSong(id: "s3", title: "Pulse Groove", status: "Idea", versionCount: 2, lastTouch: now.addingTimeInterval(-86400), bpm: 128, key: "F minor")
        ]
        decisions = [
            MobileDecision(id: "d1", kind: .competing, songTitle: "Night Drive", detail: "2 hook takes competing for the same slot"),
            MobileDecision(id: "d2", kind: .master, songTitle: "Golden State", detail: "A newer mix is challenging your pinned master")
        ]
        recent = [
            MobileEvent(id: "e1", summary: "Stacked night drive FINAL as the latest version", songTitle: "Night Drive", at: now.addingTimeInterval(-1800)),
            MobileEvent(id: "e2", summary: "Detected 120 BPM · A minor", songTitle: "Night Drive", at: now.addingTimeInterval(-2400)),
            MobileEvent(id: "e3", summary: "New bounce imported from Files", songTitle: "Golden State", at: now.addingTimeInterval(-5400))
        ]
    }

    /// Proves ArtistOSCore is linked into the iOS build (replaced by real use soon).
    func coreLinked() -> Bool {
        let v = Assembly.validateRecipe([
            Assembly.Pick(slotId: "x", label: "Verse", assetId: "a", start: 0, end: 8, bpm: 120, keyName: "A minor")
        ])
        return v.ok
    }
}

extension Date {
    var agoShort: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
