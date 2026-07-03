import XCTest
@testable import ArtistOS

@MainActor
final class ReconciliationTests: XCTestCase {
    private var root: URL!
    private var store: CatalogStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Career-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Song X"),
            withIntermediateDirectories: true
        )
        store = CatalogStore(database: try AppDatabase.inMemory())
        try store.save(watchedFolder: WatchedFolder(
            id: UUID(), path: root.path, bookmark: nil, addedAt: Date()
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeState() -> AppState {
        AppState(store: store, seedIfNeeded: false, enableWatching: false)
    }

    func testReconcileImportsRerunsIdempotentlyAndArchivesOnce() async throws {
        let fileA = root.appendingPathComponent("Song X/take1.wav")
        let fileB = root.appendingPathComponent("loose.m4a")
        try Data([1, 2, 3]).write(to: fileA)
        try Data([4, 5, 6]).write(to: fileB)

        let state = makeState()
        XCTAssertEqual(state.watchedFolders.count, 1)
        XCTAssertTrue(state.catalog.songs.isEmpty)

        await state.reconcileWatchedFolders()
        XCTAssertEqual(state.catalog.songs.count, 2)
        XCTAssertEqual(state.catalog.assets.count, 2)
        XCTAssertTrue(state.catalog.events.contains {
            $0.operation == .imported && $0.summary.contains("observed")
        })

        // Idempotent: nothing changed on disk, nothing new in catalog.
        let eventCount = state.catalog.events.count
        await state.reconcileWatchedFolders()
        XCTAssertEqual(state.catalog.assets.count, 2)
        XCTAssertEqual(state.catalog.events.count, eventCount)

        // Deletion → exactly one archived event, even across repeated passes.
        try FileManager.default.removeItem(at: fileA)
        await state.reconcileWatchedFolders()
        await state.reconcileWatchedFolders()
        let archived = state.catalog.events.filter { $0.operation == .archived }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.confidence ?? 0, 0.8, accuracy: 0.001)
    }

    func testReconcileDetectsModifiedFileAndRefreshesMetadata() async throws {
        let file = root.appendingPathComponent("Song X/hook.wav")
        try Data([1, 1, 1]).write(to: file)

        let state = makeState()
        await state.reconcileWatchedFolders()
        XCTAssertEqual(state.catalog.assets.count, 1)
        let originalHash = state.catalog.assets[0].contentHash
        XCTAssertNotNil(state.catalog.assets[0].fileModifiedAt)

        // Rewrite contents and push the modification date clearly forward.
        try Data([7, 7, 7, 7, 7]).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: file.path
        )

        await state.reconcileWatchedFolders()
        XCTAssertTrue(state.catalog.events.contains { $0.operation == .recordingUpdated })
        XCTAssertEqual(state.catalog.assets.count, 1)
        XCTAssertNotEqual(state.catalog.assets[0].contentHash, originalHash)
        XCTAssertEqual(state.catalog.assets[0].contentHash, ImportService.contentHash(of: file))

        // Stable afterwards: no repeat events without a new change.
        let eventCount = state.catalog.events.count
        await state.reconcileWatchedFolders()
        XCTAssertEqual(state.catalog.events.count, eventCount)
    }

    func testReconcilePersistsAcrossRelaunch() async throws {
        try Data([2, 2]).write(to: root.appendingPathComponent("Song X/beat.wav"))

        let first = makeState()
        await first.reconcileWatchedFolders()
        XCTAssertEqual(first.catalog.assets.count, 1)

        // Simulate relaunch against the same database.
        let second = makeState()
        XCTAssertEqual(second.catalog.assets.count, 1)
        XCTAssertEqual(second.catalog.songs.count, 1)
        await second.reconcileWatchedFolders()
        XCTAssertEqual(second.catalog.assets.count, 1)
    }
}
