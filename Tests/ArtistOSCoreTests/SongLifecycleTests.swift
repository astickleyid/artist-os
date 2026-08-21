import XCTest
@testable import ArtistOSCore

final class SongLifecycleTests: XCTestCase {
    func testArchiveChangesOnlyStatusAndTimestamp() {
        let originalTime = Date(timeIntervalSince1970: 100)
        let archivedTime = Date(timeIntervalSince1970: 200)
        let section = MasterSection(
            id: UUID(),
            name: "Hook",
            role: "Hook",
            assetID: UUID(),
            state: .locked,
            confidence: 0.94,
            note: "Keep this take"
        )
        let song = Song(
            id: UUID(),
            title: "Golden State",
            era: "Current",
            status: .review,
            progress: 0.82,
            qualityScore: 0.91,
            risk: "Low",
            sections: [section],
            masterAssetID: UUID(),
            updatedAt: originalTime
        )

        let archived = SongLifecycle.archive(song, at: archivedTime)

        XCTAssertEqual(archived.id, song.id)
        XCTAssertEqual(archived.title, song.title)
        XCTAssertEqual(archived.era, song.era)
        XCTAssertEqual(archived.progress, song.progress)
        XCTAssertEqual(archived.qualityScore, song.qualityScore)
        XCTAssertEqual(archived.risk, song.risk)
        XCTAssertEqual(archived.sections, song.sections)
        XCTAssertEqual(archived.masterAssetID, song.masterAssetID)
        XCTAssertEqual(archived.status, .archived)
        XCTAssertEqual(archived.updatedAt, archivedTime)
    }

    func testRestorePreservesSongIdentityAndCreativeState() {
        let restoreTime = Date(timeIntervalSince1970: 300)
        let section = MasterSection(
            id: UUID(),
            name: "Verse",
            role: "Verse",
            assetID: UUID(),
            state: .needsDecision,
            confidence: 0.61,
            note: "Compare alternates"
        )
        let archived = Song(
            id: UUID(),
            title: "Archive Test",
            era: "2026",
            status: .archived,
            progress: 0.4,
            qualityScore: 0.7,
            risk: "Medium",
            sections: [section],
            masterAssetID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 250)
        )

        let restored = SongLifecycle.restore(archived, to: .review, at: restoreTime)

        XCTAssertEqual(restored.id, archived.id)
        XCTAssertEqual(restored.title, archived.title)
        XCTAssertEqual(restored.sections, archived.sections)
        XCTAssertEqual(restored.masterAssetID, archived.masterAssetID)
        XCTAssertEqual(restored.status, .review)
        XCTAssertEqual(restored.updatedAt, restoreTime)
    }

    func testLifecycleTransitionsAreIdempotentWhenNoChangeIsNeeded() {
        let archived = Song(
            id: UUID(),
            title: "Already Archived",
            era: "",
            status: .archived,
            progress: 0,
            qualityScore: 0,
            risk: "",
            sections: [],
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        XCTAssertEqual(SongLifecycle.archive(archived, at: Date(timeIntervalSince1970: 100)), archived)
        XCTAssertEqual(SongLifecycle.restore(archived, to: .archived, at: Date(timeIntervalSince1970: 100)), archived)
    }
}
