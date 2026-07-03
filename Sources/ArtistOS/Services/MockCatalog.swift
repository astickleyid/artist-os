import Foundation

enum MockCatalog {
    static func make() -> ArtistCatalog {
        let songID = UUID()
        let beat = Asset(id: UUID(), title: "Beat is M9", originalFilename: "beat is m9.m4a", role: .beat, createdAt: Date(), duration: 199, localURLBookmark: nil, songID: songID)
        let soda = Asset(id: UUID(), title: "Soda7draft", originalFilename: "soda7draft.m4a", role: .leadVocal, createdAt: Date(), duration: 252, localURLBookmark: nil, songID: songID)
        let baddest = Asset(id: UUID(), title: "Baddest Times", originalFilename: "baddest times(1).m4a", role: .hook, createdAt: Date(), duration: 210, localURLBookmark: nil, songID: songID)
        let candid = Asset(id: UUID(), title: "Candid Camera", originalFilename: "candidcamera(apple master)_1.m4a", role: .bridge, createdAt: Date(), duration: 258, localURLBookmark: nil, songID: songID)

        let song = Song(
            id: songID,
            title: "Golden State",
            era: "Golden State",
            status: .assembling,
            progress: 0.68,
            qualityScore: 0.81,
            risk: "Hook decision unresolved",
            sections: [
                MasterSection(id: UUID(), name: "Intro", role: "Atmosphere", assetID: beat.id, state: .locked, confidence: 0.88, note: "m9 bed selected as current intro source."),
                MasterSection(id: UUID(), name: "Verse 1", role: "Lead vocal", assetID: soda.id, state: .candidate, confidence: 0.74, note: "Working vocal candidate."),
                MasterSection(id: UUID(), name: "Hook", role: "Melody", assetID: baddest.id, state: .needsDecision, confidence: 0.79, note: "Needs A/B before master approval."),
                MasterSection(id: UUID(), name: "Bridge", role: "Alt pocket", assetID: candid.id, state: .experiment, confidence: 0.63, note: "Experiment slot; not replacing recording."),
                MasterSection(id: UUID(), name: "Outro", role: "Space", assetID: beat.id, state: .open, confidence: 0.72, note: "Structure pending.")
            ]
        )

        let events = [
            CreativeEvent(id: UUID(), songID: songID, timestamp: Date(), target: .intro, operation: .sourceSelected, beforeAssetID: nil, afterAssetID: beat.id, summary: "m9 bed selected as current intro source.", confidence: 0.90),
            CreativeEvent(id: UUID(), songID: songID, timestamp: Date(), target: .verse, operation: .candidateAdded, beforeAssetID: nil, afterAssetID: soda.id, summary: "candidate vocal source added to working master.", confidence: 0.74),
            CreativeEvent(id: UUID(), songID: songID, timestamp: Date(), target: .hook, operation: .candidateAdded, beforeAssetID: nil, afterAssetID: baddest.id, summary: "melody-first hook candidate added; not master-approved.", confidence: 0.79),
            CreativeEvent(id: UUID(), songID: songID, timestamp: Date(), target: .bridge, operation: .needsDecision, beforeAssetID: candid.id, afterAssetID: nil, summary: "future mix experiments attach here without replacing recording.", confidence: 0.63)
        ]

        return ArtistCatalog(artistName: "STICK", songs: [song], assets: [beat, soda, baddest, candid], events: events)
    }
}
