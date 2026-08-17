import XCTest
import ArtistOSCore
@testable import ArtistOS

@MainActor
final class CanonicalApprovalSyncTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "artistos-canonical-approval-sync-\(UUID().uuidString)")!
    }

    func testSectionApprovalPushesDecisionAndMasterCompositionWithFacts() async throws {
        let fake = FakeHTTPClient(script: [
            .init(json: ["accountId": "acc1", "token": "tok1"], status: 201),
            .init(json: ["applied": 3, "skipped": 0, "seq": 3]),
            .init(json: ["applied": 5, "skipped": 0, "seq": 8])
        ])
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let state = AppState(
            store: store,
            seedIfNeeded: false,
            enableWatching: false,
            sync: SyncService(client: fake, defaults: freshDefaults())
        )

        state.createSong(title: "Canonical Approval")
        let song = try XCTUnwrap(state.catalog.songs.first)
        let sectionID = song.sections[2].id
        let winner = Asset(
            id: UUID(), title: "Hook B", originalFilename: "hook-b.wav", role: .hook,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        let loser = Asset(
            id: UUID(), title: "Hook A", originalFilename: "hook-a.wav", role: .hook,
            createdAt: Date(), duration: nil, localURLBookmark: nil, songID: song.id
        )
        state.catalog.assets.append(contentsOf: [winner, loser])
        try store.insert(asset: winner)
        try store.insert(asset: loser)
        state.setState(.needsDecision, sectionID: sectionID, songID: song.id)

        await state.enableSync()
        XCTAssertEqual(state.syncStatus, .on)

        state.approveSectionDecision(
            sectionID: sectionID,
            songID: song.id,
            winner: winner.id,
            rejectedAssetIDs: [loser.id],
            reason: "Better delivery"
        )

        for _ in 0..<50 {
            if await fake.recorded.count >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let requestCount = await fake.recorded.count
        XCTAssertEqual(requestCount, 3, "account creation + initial catalog push + canonical approval push")
        let body = await fake.lastBodyJSON()
        let changes = try XCTUnwrap(body?["changes"] as? [[String: Any]])
        let kinds = changes.compactMap { $0["kind"] as? String }

        XCTAssertEqual(kinds.filter { $0 == "song" }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == "event" }.count, 2)
        XCTAssertEqual(kinds.filter { $0 == SyncLogic.decisionKind }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == SyncLogic.masterCompositionKind }.count, 1)

        let decisionChange = try XCTUnwrap(changes.first { ($0["kind"] as? String) == SyncLogic.decisionKind })
        let decisionData = try XCTUnwrap(decisionChange["data"] as? [String: Any])
        XCTAssertEqual(decisionData["selectedAssetId"] as? String, winner.id.uuidString)
        XCTAssertEqual(decisionData["reason"] as? String, "Better delivery")

        let compositionChange = try XCTUnwrap(changes.first {
            ($0["kind"] as? String) == SyncLogic.masterCompositionKind
        })
        let compositionData = try XCTUnwrap(compositionChange["data"] as? [String: Any])
        let sections = try XCTUnwrap(compositionData["sections"] as? [[String: Any]])
        let hook = try XCTUnwrap(sections.first { ($0["id"] as? String) == sectionID.uuidString })
        let selections = try XCTUnwrap(hook["selections"] as? [[String: Any]])
        let source = try XCTUnwrap(selections.first { ($0["kind"] as? String) == "Source Asset" })
        XCTAssertEqual(source["referenceId"] as? String, winner.id.uuidString)
        XCTAssertEqual(source["decisionId"] as? String, decisionChange["id"] as? String)
    }
}
