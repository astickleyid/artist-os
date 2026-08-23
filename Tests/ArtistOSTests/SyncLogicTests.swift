import XCTest
import ArtistOSCore
@testable import ArtistOS

final class SyncLogicTests: XCTestCase {

    func testSongPayloadIncludesCoreFieldsButOmitsRetiredSourceMirrors() {
        let sectionAssetID = UUID()
        let masterAssetID = UUID()
        let section = MasterSection(id: UUID(), name: "Hook", role: "hook", assetID: sectionAssetID,
                                     state: .open, confidence: 0, note: "")
        let song = Song(id: UUID(), title: "Night Drive", era: "2026", status: .review,
                        progress: 0.5, qualityScore: 80, risk: "low", sections: [section],
                        masterAssetID: masterAssetID)
        let change = SyncLogic.change(forSong: song)
        XCTAssertEqual(change["kind"] as? String, "song")
        XCTAssertEqual(change["id"] as? String, song.id.uuidString)
        let data = change["data"] as? SyncLogic.JSONDict
        XCTAssertEqual(data?["title"] as? String, "Night Drive")
        XCTAssertNil(data?["masterAssetId"], "current master belongs in MasterComposition sync")
        let sections = data?["sections"] as? [SyncLogic.JSONDict]
        XCTAssertEqual(sections?.first?["name"] as? String, "Hook")
        XCTAssertNil(sections?.first?["assetID"], "current section source belongs in MasterComposition sync")
    }

    func testTombstoneCarriesNoData() {
        let change = SyncLogic.tombstone(kind: .asset, id: "abc")
        XCTAssertEqual(change["deleted"] as? Bool, true)
        XCTAssertNil(change["data"])
    }

    func testConflictResolutionNewerWinsOlderIgnored() {
        let base = Date()
        XCTAssertTrue(SyncLogic.shouldApplyRemote(
            updatedAt: (base.timeIntervalSince1970 + 10) * 1000, overLocal: base))
        XCTAssertFalse(SyncLogic.shouldApplyRemote(
            updatedAt: (base.timeIntervalSince1970 - 10) * 1000, overLocal: base))
        XCTAssertFalse(SyncLogic.shouldApplyRemote( // tie -> local wins
            updatedAt: base.timeIntervalSince1970 * 1000, overLocal: base))
    }

    func testMergedSongRoundTripsThroughPayload() {
        let original = Song(id: UUID(), title: "A", era: "2026", status: .queue,
                             progress: 0.2, qualityScore: 40, risk: "medium", sections: [])
        let payload = SyncLogic.songPayload(original)
        let merged = SyncLogic.mergedSong(payload: payload, updatedAt: Date(), existing: nil)
        XCTAssertEqual(merged?.id, original.id)
        XCTAssertEqual(merged?.title, "A")
        XCTAssertEqual(merged?.status, .queue)
        XCTAssertEqual(merged?.risk, "medium")
    }

    func testMergedSongPreservesExistingWhenFieldMissing() {
        var existing = Song(id: UUID(), title: "Original", era: "2020", status: .assembling,
                             progress: 0, qualityScore: 0, risk: "low", sections: [])
        existing.masterAssetID = UUID()
        // Payload deliberately omits "era" to simulate a future/older client sending a partial shape.
        let payload: SyncLogic.JSONDict = ["id": existing.id.uuidString, "title": "Updated"]
        let merged = SyncLogic.mergedSong(payload: payload, updatedAt: Date(), existing: existing)
        XCTAssertEqual(merged?.title, "Updated")
        XCTAssertEqual(merged?.era, "2020", "fields absent from the payload must not be clobbered")
    }

    func testMergedAssetRoundTrips() {
        let original = Asset(id: UUID(), title: "Take 1", originalFilename: "take1.wav", role: .hook,
                              createdAt: Date(), duration: nil, localURLBookmark: nil,
                              version: "v2", vOrder: 2, bpm: 120.5, musicalKey: "A minor")
        let payload = SyncLogic.assetPayload(original)
        let merged = SyncLogic.mergedAsset(payload: payload, updatedAt: Date(), existing: nil)
        XCTAssertEqual(merged?.role, .hook)
        XCTAssertEqual(merged?.vOrder, 2)
        XCTAssertEqual(merged?.bpm, 120.5)
        XCTAssertEqual(merged?.musicalKey, "A minor")
    }

    func testMalformedPayloadWithoutIdReturnsNil() {
        XCTAssertNil(SyncLogic.mergedSong(payload: ["title": "no id"], updatedAt: Date(), existing: nil))
        XCTAssertNil(SyncLogic.mergedAsset(payload: [:], updatedAt: Date(), existing: nil))
    }

    func testLegacySectionDecoderStillAcceptsSourceMirrorFromOlderClients() {
        let assetID = UUID()
        let dict: SyncLogic.JSONDict = [
            "id": UUID().uuidString,
            "name": "Bridge",
            "role": "bridge",
            "assetID": assetID.uuidString,
            "state": SectionState.locked.rawValue,
            "confidence": 0.9,
            "note": "great take"
        ]
        let decoded = SyncLogic.section(from: dict)
        XCTAssertEqual(decoded?.state, .locked)
        XCTAssertEqual(decoded?.assetID, assetID)
        XCTAssertEqual(decoded?.note, "great take")
    }

    func testLegacySongDecoderStillAcceptsMasterMirrorFromOlderClients() {
        let songID = UUID()
        let masterAssetID = UUID()
        let payload: SyncLogic.JSONDict = [
            "id": songID.uuidString,
            "title": "Legacy",
            "masterAssetId": masterAssetID.uuidString,
            "sections": []
        ]
        let merged = SyncLogic.mergedSong(payload: payload, updatedAt: Date(), existing: nil)
        XCTAssertEqual(merged?.masterAssetID, masterAssetID)
    }

    func testSectionEncodingOmitsRetiredSourceMirror() {
        let section = MasterSection(id: UUID(), name: "Bridge", role: "bridge",
                                     assetID: UUID(), state: .locked, confidence: 0.9, note: "great take")
        let dict = SyncLogic.dict(fromSection: section)
        XCTAssertNil(dict["assetID"])
        let decoded = SyncLogic.section(from: dict)
        XCTAssertEqual(decoded?.id, section.id)
        XCTAssertEqual(decoded?.state, .locked)
        XCTAssertNil(decoded?.assetID)
        XCTAssertEqual(decoded?.note, "great take")
    }
}
