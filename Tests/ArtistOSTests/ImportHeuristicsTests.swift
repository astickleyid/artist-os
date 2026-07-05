import XCTest
import ArtistOSCore
@testable import ArtistOS

final class ImportHeuristicsTests: XCTestCase {
    func testRoleInference() {
        XCTAssertEqual(ImportService.inferRole(filename: "trap beat v3.wav"), .beat)
        XCTAssertEqual(ImportService.inferRole(filename: "hook_take2.m4a"), .hook)
        XCTAssertEqual(ImportService.inferRole(filename: "Chorus idea.mp3"), .hook)
        XCTAssertEqual(ImportService.inferRole(filename: "bridge-alt.aif"), .bridge)
        XCTAssertEqual(ImportService.inferRole(filename: "lead VOCAL comp.wav"), .leadVocal)
        XCTAssertEqual(ImportService.inferRole(filename: "verse 1 vox.m4a"), .leadVocal)
        XCTAssertEqual(ImportService.inferRole(filename: "ref track.mp3"), .reference)
        XCTAssertEqual(ImportService.inferRole(filename: "final bounce.wav"), .fullMix)
    }

    func testTitleize() {
        XCTAssertEqual(ImportService.titleize("soda7draft.m4a"), "soda7draft")
        XCTAssertEqual(ImportService.titleize("beat_is-m9.wav"), "beat is m9")
        XCTAssertEqual(ImportService.titleize("Song A", stripExtension: false), "Song A")
        XCTAssertEqual(ImportService.titleize("  spaced   out  .mp3"), "spaced out")
    }

    func testDefaultSongStructure() {
        let song = ImportService.makeSong(title: "Test")
        XCTAssertEqual(song.title, "Test")
        XCTAssertEqual(song.sections.count, 5)
        XCTAssertTrue(song.sections.allSatisfy { $0.state == .open && $0.assetID == nil })
        XCTAssertEqual(song.progress, 0)
    }

    func testFolderGrouping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aos-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Song A/stems"),
            withIntermediateDirectories: true
        )
        try Data([0x00]).write(to: root.appendingPathComponent("Song A/take1.wav"))
        try Data([0x00]).write(to: root.appendingPathComponent("Song A/stems/beat.mp3"))
        try Data([0x00]).write(to: root.appendingPathComponent("loose.m4a"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let outcome = try await ImportService.scan(folder: root) { _, _ in }

        XCTAssertEqual(outcome.songs.count, 2)
        XCTAssertEqual(outcome.skippedFiles, 1)

        let songA = outcome.songs.first { $0.song.title == "Song A" }
        XCTAssertNotNil(songA)
        XCTAssertEqual(songA?.assets.count, 2)
        XCTAssertTrue(songA?.assets.allSatisfy { $0.songID == songA?.song.id } ?? false)

        let loose = outcome.songs.first { $0.song.title != "Song A" }
        XCTAssertEqual(loose?.assets.count, 1)
        XCTAssertEqual(loose?.assets.first?.originalFilename, "loose.m4a")
    }
}
