import XCTest
@testable import ArtistOS

final class DedupAndWatchTests: XCTestCase {
    func testContentHashStableAndDistinct() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aos-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let a = dir.appendingPathComponent("a.wav")
        let b = dir.appendingPathComponent("b.wav")
        let c = dir.appendingPathComponent("c.wav")
        try Data([1, 2, 3, 4]).write(to: a)
        try Data([1, 2, 3, 4]).write(to: b)
        try Data([9, 9, 9]).write(to: c)

        let hashA = ImportService.contentHash(of: a)
        let hashB = ImportService.contentHash(of: b)
        let hashC = ImportService.contentHash(of: c)

        XCTAssertNotNil(hashA)
        XCTAssertEqual(hashA, hashB)
        XCTAssertNotEqual(hashA, hashC)
        XCTAssertEqual(hashA?.count, 64)
    }

    func testPartitionDuplicates() {
        func asset(hash: String?) -> Asset {
            Asset(id: UUID(), title: "x", originalFilename: "x.wav", role: .fullMix,
                  createdAt: Date(), duration: nil, localURLBookmark: nil, contentHash: hash)
        }
        let result = ImportService.partitionDuplicates(
            assets: [asset(hash: "aaa"), asset(hash: "aaa"), asset(hash: "bbb"),
                     asset(hash: "ccc"), asset(hash: nil)],
            existingHashes: ["bbb"]
        )
        XCTAssertEqual(result.unique.count, 3) // aaa, ccc, nil-hash
        XCTAssertEqual(result.duplicateCount, 2) // second aaa, bbb
    }

    func testGroupForURL() {
        let base = URL(fileURLWithPath: "/tmp/Career")
        XCTAssertEqual(
            ImportService.group(for: URL(fileURLWithPath: "/tmp/Career/Song A/take.wav"), base: base),
            "Song A"
        )
        XCTAssertEqual(
            ImportService.group(for: URL(fileURLWithPath: "/tmp/Career/Song A/stems/beat.wav"), base: base),
            "Song A"
        )
        XCTAssertEqual(
            ImportService.group(for: URL(fileURLWithPath: "/tmp/Career/loose.wav"), base: base),
            "Career"
        )
    }

    func testWatchedFolderPersistence() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        XCTAssertTrue(store.watchedFolders().isEmpty)

        let folder = WatchedFolder(id: UUID(), path: "/tmp/Career", bookmark: nil, addedAt: Date())
        try store.save(watchedFolder: folder)
        XCTAssertEqual(store.watchedFolders().count, 1)
        XCTAssertEqual(store.watchedFolders().first?.path, "/tmp/Career")

        // Same path replaces rather than duplicates.
        let again = WatchedFolder(id: UUID(), path: "/tmp/Career", bookmark: nil, addedAt: Date())
        try store.save(watchedFolder: again)
        XCTAssertEqual(store.watchedFolders().count, 1)
        XCTAssertEqual(store.watchedFolders().first?.id, again.id)

        try store.deleteWatchedFolder(id: again.id)
        XCTAssertTrue(store.watchedFolders().isEmpty)
    }

    func testAssetContentHashRoundTrip() throws {
        let store = CatalogStore(database: try AppDatabase.inMemory())
        let song = ImportService.makeSong(title: "Hashy")
        try store.upsert(song: song)
        let asset = Asset(id: UUID(), title: "A", originalFilename: "a.wav", role: .beat,
                          createdAt: Date(), duration: nil, localURLBookmark: nil,
                          songID: song.id, contentHash: "deadbeef")
        try store.insert(asset: asset)
        XCTAssertEqual(store.loadCatalog(artistName: "T").assets.first?.contentHash, "deadbeef")
    }
}
