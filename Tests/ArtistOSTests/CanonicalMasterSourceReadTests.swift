import XCTest
import ArtistOSCore
@testable import ArtistOS

final class CanonicalMasterSourceReadTests: XCTestCase {
    func testPersistedCanonicalNoSourceDoesNotResurrectLegacySource() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Canonical Empty Source")
        let legacySourceID = UUID()
        song.sections[0].assetID = legacySourceID
        try store.upsert(song: song)

        let canonical = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: [
                MasterCompositionSection(
                    id: song.sections[0].id,
                    name: song.sections[0].name,
                    role: song.sections[0].role,
                    selections: [],
                    state: .open,
                    confidence: 0
                )
            ]
        )
        try store.upsert(masterComposition: canonical)

        let loaded = store.loadCatalog(artistName: "T")
        let resolved = try XCTUnwrap(loaded.masterComposition(for: song.id))
        let section = try XCTUnwrap(resolved.sections.first)

        XCTAssertNil(section.selection(.sourceAsset))
        XCTAssertEqual(
            loaded.songs.first?.sections.first?.assetID,
            legacySourceID,
            "The compatibility mirror may still exist, but it must not regain read precedence over canonical truth."
        )
    }

    func testPersistedCanonicalMasterOutputWinsLegacySongMasterMirror() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Canonical Master Output")
        let legacyMasterID = UUID()
        let canonicalMasterID = UUID()
        song.masterAssetID = legacyMasterID
        try store.upsert(song: song)

        let canonical = MasterComposition(
            id: UUID(),
            songID: song.id,
            sections: MasterComposition.projected(from: song).sections,
            outputAssetID: canonicalMasterID
        )
        try store.upsert(masterComposition: canonical)

        let loaded = store.loadCatalog(artistName: "T")
        let resolved = try XCTUnwrap(loaded.masterComposition(for: song.id))

        XCTAssertEqual(resolved.outputAssetID, canonicalMasterID)
        XCTAssertEqual(
            loaded.songs.first?.masterAssetID,
            legacyMasterID,
            "The compatibility mirror may remain divergent, but canonical output must retain read precedence."
        )
    }
}
