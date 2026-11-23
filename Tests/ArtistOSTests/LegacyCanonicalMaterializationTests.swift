import XCTest
import ArtistOSCore
@testable import ArtistOS

final class LegacyCanonicalMaterializationTests: XCTestCase {
    func testLegacyRowsMaterializeCanonicalMasterCompositionBeforeFieldRetirement() throws {
        let database = try AppDatabase.inMemory()
        let store = CatalogStore(database: database)
        let sourceID = UUID()
        let outputID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 1_800_123_456.25)

        var song = ImportService.makeSong(title: "Legacy Upgrade")
        song.updatedAt = updatedAt
        song.masterAssetID = outputID
        song.sections[0].assetID = sourceID
        song.sections[0].state = .locked
        song.sections[0].confidence = 0.93
        song.sections[0].note = "Approved legacy source"
        try store.upsert(song: song)

        XCTAssertTrue(store.loadCatalog(artistName: "T").masterCompositions.isEmpty)

        try database.dbQueue.write { db in
            try AppDatabase.materializeLegacyMasterCompositions(in: db)
        }

        let reloaded = store.loadCatalog(artistName: "T")
        let composition = try XCTUnwrap(reloaded.masterCompositions.first { $0.songID == song.id })
        let sourceSelection = try XCTUnwrap(composition.sections[0].selection(.sourceAsset))
        XCTAssertEqual(composition.id, song.id)
        XCTAssertEqual(composition.outputAssetID, outputID)
        XCTAssertEqual(composition.sections.map(\.id), song.sections.map(\.id))
        XCTAssertEqual(composition.sections.map(\.name), song.sections.map(\.name))
        XCTAssertEqual(composition.sections.map(\.role), song.sections.map(\.role))
        XCTAssertEqual(sourceSelection.referenceID, sourceID)
        XCTAssertNil(sourceSelection.decisionID)
        XCTAssertEqual(composition.sections[0].state, .locked)
        XCTAssertEqual(composition.sections[0].confidence, 0.93, accuracy: 0.0001)
        XCTAssertEqual(composition.sections[0].note, "Approved legacy source")
        XCTAssertEqual(
            composition.updatedAt.timeIntervalSince1970,
            updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testMaterializationNeverOverwritesPersistedCanonicalTruth() throws {
        let database = try AppDatabase.inMemory()
        let store = CatalogStore(database: database)
        let legacySourceID = UUID()
        let canonicalSourceID = UUID()
        let legacyOutputID = UUID()
        let canonicalOutputID = UUID()
        let canonicalUpdatedAt = Date(timeIntervalSince1970: 1_800_200_000)

        var song = ImportService.makeSong(title: "Canonical Wins")
        song.masterAssetID = legacyOutputID
        song.sections[0].assetID = legacySourceID
        try store.upsert(song: song)

        var canonicalSection = MasterCompositionSection(
            id: song.sections[0].id,
            name: song.sections[0].name,
            role: song.sections[0].role,
            state: .needsDecision,
            confidence: 0.42,
            note: "Canonical note"
        )
        canonicalSection.setSelection(
            MasterSelection(kind: .sourceAsset, referenceID: canonicalSourceID)
        )
        let canonical = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [canonicalSection],
            outputAssetID: canonicalOutputID,
            updatedAt: canonicalUpdatedAt
        )
        try store.upsert(masterComposition: canonical)

        try database.dbQueue.write { db in
            try AppDatabase.materializeLegacyMasterCompositions(in: db)
        }

        let reloaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(reloaded.masterCompositions.count, 1)
        let persisted = try XCTUnwrap(reloaded.masterCompositions.first)
        let persistedSection = try XCTUnwrap(persisted.sections.first)
        XCTAssertEqual(persisted.id, canonical.id)
        XCTAssertEqual(persisted.songID, song.id)
        XCTAssertEqual(persisted.outputAssetID, canonicalOutputID)
        XCTAssertEqual(persistedSection.id, canonicalSection.id)
        XCTAssertEqual(persistedSection.name, canonicalSection.name)
        XCTAssertEqual(persistedSection.role, canonicalSection.role)
        XCTAssertEqual(persistedSection.state, .needsDecision)
        XCTAssertEqual(persistedSection.confidence, 0.42, accuracy: 0.0001)
        XCTAssertEqual(persistedSection.note, "Canonical note")
        XCTAssertEqual(
            persistedSection.selection(.sourceAsset)?.referenceID,
            canonicalSourceID
        )
        XCTAssertNotEqual(
            persistedSection.selection(.sourceAsset)?.referenceID,
            legacySourceID
        )
        XCTAssertEqual(
            persisted.updatedAt.timeIntervalSince1970,
            canonicalUpdatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}