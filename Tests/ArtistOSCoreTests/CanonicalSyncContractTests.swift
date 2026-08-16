import XCTest
@testable import ArtistOSCore

final class CanonicalSyncContractTests: XCTestCase {
    func testDecisionRoundTripPreservesIntentGraph() throws {
        let songID = UUID()
        let selected = UUID()
        let rejected = [UUID(), UUID()]
        let events = [UUID(), UUID()]
        let decision = CreativeDecision(
            id: UUID(),
            songID: songID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            target: .hook,
            action: .approved,
            selectedAssetID: selected,
            rejectedAssetIDs: rejected,
            relatedEventIDs: events,
            reason: "Stronger pocket and cleaner emotion",
            source: .artist
        )

        let change = SyncLogic.change(forDecision: decision)
        XCTAssertEqual(change["kind"] as? String, SyncLogic.decisionKind)
        let payload = try XCTUnwrap(change["data"] as? SyncLogic.JSONDict)
        let updatedAt = SyncLogic.date(fromMs: try XCTUnwrap((change["updatedAt"] as? NSNumber)?.doubleValue))
        let decoded = try XCTUnwrap(SyncLogic.decision(payload: payload, updatedAt: updatedAt))

        XCTAssertEqual(decoded.id, decision.id)
        XCTAssertEqual(decoded.songID, songID)
        XCTAssertEqual(decoded.target, .hook)
        XCTAssertEqual(decoded.action, .approved)
        XCTAssertEqual(decoded.selectedAssetID, selected)
        XCTAssertEqual(decoded.rejectedAssetIDs, rejected)
        XCTAssertEqual(decoded.relatedEventIDs, events)
        XCTAssertEqual(decoded.reason, decision.reason)
        XCTAssertEqual(decoded.source, .artist)
    }

    func testMasterCompositionRoundTripPreservesIndependentLayersAndDecisionLinks() throws {
        let songID = UUID()
        let decisionID = UUID()
        let sourceID = UUID()
        let processingID = UUID()
        let section = MasterCompositionSection(
            id: UUID(),
            name: "Hook",
            role: "Hook",
            selections: [
                MasterSelection(
                    id: UUID(), kind: .sourceAsset, referenceID: sourceID,
                    decisionID: decisionID, selectedAt: Date(timeIntervalSince1970: 1_700_000_001)
                ),
                MasterSelection(
                    id: UUID(), kind: .processingSnapshot, referenceID: processingID,
                    selectedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
            ],
            state: .locked,
            confidence: 0.96,
            note: "Current hook"
        )
        let composition = MasterComposition(
            id: UUID(),
            songID: songID,
            sections: [section],
            outputAssetID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_003)
        )

        let change = SyncLogic.change(forMasterComposition: composition)
        XCTAssertEqual(change["kind"] as? String, SyncLogic.masterCompositionKind)
        let payload = try XCTUnwrap(change["data"] as? SyncLogic.JSONDict)
        let updatedAt = SyncLogic.date(fromMs: try XCTUnwrap((change["updatedAt"] as? NSNumber)?.doubleValue))
        let decoded = try XCTUnwrap(SyncLogic.masterComposition(payload: payload, updatedAt: updatedAt))

        XCTAssertEqual(decoded.id, composition.id)
        XCTAssertEqual(decoded.songID, songID)
        XCTAssertEqual(decoded.outputAssetID, composition.outputAssetID)
        XCTAssertEqual(decoded.sections.count, 1)
        XCTAssertEqual(decoded.sections[0].selection(.sourceAsset)?.referenceID, sourceID)
        XCTAssertEqual(decoded.sections[0].selection(.sourceAsset)?.decisionID, decisionID)
        XCTAssertEqual(decoded.sections[0].selection(.processingSnapshot)?.referenceID, processingID)
        XCTAssertEqual(decoded.sections[0].state, .locked)
        XCTAssertEqual(decoded.sections[0].confidence, 0.96, accuracy: 0.0001)
    }

    func testEventPayloadKeepsBeforeAndAfterEvidence() throws {
        let before = UUID()
        let after = UUID()
        let event = CreativeEvent(
            id: UUID(), songID: UUID(), timestamp: Date(), target: .verse,
            operation: .recordingUpdated, beforeAssetID: before, afterAssetID: after,
            summary: "Lead changed", confidence: 1
        )
        let payload = SyncLogic.eventPayload(event)
        XCTAssertEqual(payload["beforeAssetId"] as? String, before.uuidString)
        XCTAssertEqual(payload["afterAssetId"] as? String, after.uuidString)
    }
}
