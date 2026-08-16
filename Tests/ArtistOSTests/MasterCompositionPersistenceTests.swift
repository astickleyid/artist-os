import XCTest
import ArtistOSCore
@testable import ArtistOS

final class MasterCompositionPersistenceTests: XCTestCase {
    private func assertDateEqual(
        _ actual: Date,
        _ expected: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.001,
            file: file,
            line: line
        )
    }

    func testPersistedCompositionRoundTripsLayeredSelections() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Layered Truth")
        try store.upsert(song: song)

        let decisionID = UUID()
        let selectedAt = Date(timeIntervalSince1970: 1_800_000_000.125)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_100.5)
        let sourceID = UUID()
        let processingID = UUID()
        let compRecipeID = UUID()
        let sectionID = UUID()

        let composition = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [
                MasterCompositionSection(
                    id: sectionID,
                    name: "Hook",
                    role: "Melody",
                    selections: [
                        MasterSelection(
                            id: UUID(),
                            kind: .sourceAsset,
                            referenceID: sourceID,
                            decisionID: decisionID,
                            selectedAt: selectedAt
                        ),
                        MasterSelection(
                            id: UUID(),
                            kind: .processingSnapshot,
                            referenceID: processingID,
                            selectedAt: selectedAt
                        ),
                        MasterSelection(
                            id: UUID(),
                            kind: .compRecipe,
                            referenceID: compRecipeID,
                            selectedAt: selectedAt
                        )
                    ],
                    state: .locked,
                    confidence: 0.94,
                    note: "Current approved hook"
                )
            ],
            outputAssetID: UUID(),
            updatedAt: updatedAt
        )

        try store.upsert(masterComposition: composition)
        let catalog = store.loadCatalog(artistName: "T")

        XCTAssertEqual(catalog.masterCompositions.count, 1)
        guard let loaded = catalog.masterCompositions.first else {
            return XCTFail("Expected persisted composition")
        }
        XCTAssertEqual(loaded.id, composition.id)
        XCTAssertEqual(loaded.songID, song.id)
        XCTAssertEqual(loaded.outputAssetID, composition.outputAssetID)
        assertDateEqual(loaded.updatedAt, updatedAt)
        XCTAssertEqual(loaded.sections.count, 1)
        XCTAssertEqual(loaded.sections[0].id, sectionID)
        XCTAssertEqual(loaded.sections[0].state, .locked)
        XCTAssertEqual(loaded.sections[0].selection(.sourceAsset)?.referenceID, sourceID)
        XCTAssertEqual(loaded.sections[0].selection(.sourceAsset)?.decisionID, decisionID)
        XCTAssertEqual(loaded.sections[0].selection(.processingSnapshot)?.referenceID, processingID)
        XCTAssertEqual(loaded.sections[0].selection(.compRecipe)?.referenceID, compRecipeID)
        XCTAssertEqual(
            loaded.sections[0].selections.map(\.kind),
            [.compRecipe, .processingSnapshot, .sourceAsset],
            "equal timestamps must reconstruct in a deterministic order"
        )
        if let loadedSelectedAt = loaded.sections[0].selection(.sourceAsset)?.selectedAt {
            assertDateEqual(loadedSelectedAt, selectedAt)
        } else {
            XCTFail("Expected source selection")
        }
    }

    func testUpsertReplacesCompositionAtomicallyForSong() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Replace Truth")
        try store.upsert(song: song)

        let oldSection = MasterCompositionSection(
            id: UUID(),
            name: "Verse 1",
            role: "Lead",
            selections: [MasterSelection(kind: .sourceAsset, referenceID: UUID())]
        )
        try store.upsert(masterComposition: MasterComposition(
            id: UUID(), songID: song.id, sections: [oldSection]
        ))

        let newSource = UUID()
        let newComposition = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [
                MasterCompositionSection(
                    id: UUID(),
                    name: "Hook",
                    role: "Melody",
                    selections: [MasterSelection(kind: .sourceAsset, referenceID: newSource)],
                    state: .locked
                )
            ]
        )
        try store.upsert(masterComposition: newComposition)

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertEqual(loaded.masterCompositions.count, 1)
        XCTAssertEqual(loaded.masterCompositions[0].id, newComposition.id)
        XCTAssertEqual(loaded.masterCompositions[0].sections.map(\.name), ["Hook"])
        XCTAssertEqual(
            loaded.masterCompositions[0].sections[0].selection(.sourceAsset)?.referenceID,
            newSource
        )
    }

    func testLegacyCatalogProjectsCompositionWithoutWritingMigrationData() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Legacy")
        let sourceID = UUID()
        song.sections[0].assetID = sourceID
        song.sections[0].state = .locked
        try store.upsert(song: song)

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertTrue(loaded.masterCompositions.isEmpty)

        let projected = try XCTUnwrap(loaded.masterComposition(for: song.id))
        XCTAssertEqual(projected.id, song.id)
        XCTAssertEqual(projected.songID, song.id)
        XCTAssertEqual(projected.sections[0].selection(.sourceAsset)?.referenceID, sourceID)
        XCTAssertEqual(projected.sections[0].state, .locked)
    }

    func testPersistedCompositionWinsOverLegacyProjection() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Canonical Wins")
        let legacySource = UUID()
        song.sections[0].assetID = legacySource
        try store.upsert(song: song)

        let canonicalSource = UUID()
        let canonical = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [
                MasterCompositionSection(
                    id: song.sections[0].id,
                    name: song.sections[0].name,
                    role: song.sections[0].role,
                    selections: [MasterSelection(kind: .sourceAsset, referenceID: canonicalSource)]
                )
            ]
        )
        try store.upsert(masterComposition: canonical)

        let loaded = store.loadCatalog(artistName: "T")
        let resolved = try XCTUnwrap(loaded.masterComposition(for: song.id))
        XCTAssertEqual(resolved.id, canonical.id)
        XCTAssertEqual(resolved.sections[0].selection(.sourceAsset)?.referenceID, canonicalSource)
        XCTAssertNotEqual(resolved.sections[0].selection(.sourceAsset)?.referenceID, legacySource)
    }

    func testDeletingSongCascadesCanonicalComposition() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Cascade Composition")
        try store.upsert(song: song)
        try store.upsert(masterComposition: MasterComposition.projected(from: song))

        try store.delete(songID: song.id)

        let loaded = store.loadCatalog(artistName: "T")
        XCTAssertTrue(loaded.songs.isEmpty)
        XCTAssertTrue(loaded.masterCompositions.isEmpty)
    }
}
