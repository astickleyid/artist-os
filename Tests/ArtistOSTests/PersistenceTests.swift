import XCTest
@testable import ArtistOS

final class PersistenceTests: XCTestCase {
    func testCatalogRoundTrip() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        XCTAssertTrue(store.isEmpty)

        var song = ImportService.makeSong(title: "Round Trip")
        try store.upsert(song: song)

        let asset = Asset(
            id: UUID(), title: "A", originalFilename: "a.wav", role: .beat,
            createdAt: Date(), duration: 12.5, localURLBookmark: nil,
            songID: song.id, sourcePath: "/tmp/a.wav", fileSize: 1024,
            format: "WAV", sampleRate: 44100, channels: 2
        )
        try store.insert(asset: asset)

        song.sections[0].assetID = asset.id
        song.sections[0].state = .locked
        try store.upsert(song: song)

        let event = CreativeEvent(
            id: UUID(), songID: song.id, timestamp: Date(),
            target: .intro, operation: .sourceSelected,
            beforeAssetID: nil, afterAssetID: asset.id,
            summary: "test", confidence: 1
        )
        try store.append(event: event)

        let catalog = store.loadCatalog(artistName: "T")
        XCTAssertEqual(catalog.songs.count, 1)
        XCTAssertEqual(catalog.songs[0].title, "Round Trip")
        XCTAssertEqual(catalog.songs[0].sections.count, 5)
        XCTAssertEqual(catalog.songs[0].sections[0].assetID, asset.id)
        XCTAssertEqual(catalog.songs[0].sections[0].state, .locked)
        XCTAssertEqual(catalog.assets.count, 1)
        XCTAssertEqual(catalog.assets[0].sampleRate, 44100)
        XCTAssertEqual(catalog.assets[0].songID, song.id)
        XCTAssertEqual(catalog.events.count, 1)
        XCTAssertEqual(catalog.events[0].operation, .sourceSelected)
    }

    func testSectionOrderPreserved() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        var song = ImportService.makeSong(title: "Ordered")
        song.sections.append(
            MasterSection(id: UUID(), name: "Verse 2", role: "Custom",
                          assetID: nil, state: .open, confidence: 0, note: "")
        )
        try store.upsert(song: song)

        let loaded = store.loadCatalog(artistName: "T").songs[0]
        XCTAssertEqual(loaded.sections.map(\.name), song.sections.map(\.name))
    }

    func testDeleteSongCascades() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Doomed")
        try store.upsert(song: song)
        try store.append(event: CreativeEvent(
            id: UUID(), songID: song.id, timestamp: Date(),
            target: .song, operation: .imported,
            beforeAssetID: nil, afterAssetID: nil, summary: "x", confidence: 1
        ))
        try store.delete(songID: song.id)

        let catalog = store.loadCatalog(artistName: "T")
        XCTAssertTrue(catalog.songs.isEmpty)
        XCTAssertTrue(catalog.events.isEmpty)
    }
}
