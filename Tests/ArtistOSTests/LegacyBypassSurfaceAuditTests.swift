import Foundation
import XCTest

final class LegacyBypassSurfaceAuditTests: XCTestCase {
    func testObsoleteAppStateBypassesHaveNoProductionCallers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            repositoryRoot.appendingPathComponent("Sources/ArtistOS", isDirectory: true),
            repositoryRoot.appendingPathComponent("Sources/ArtistOSCore", isDirectory: true)
        ]
        let appStatePath = "Sources/ArtistOS/App/AppState.swift"
        let retiredCallPatterns = [
            "deleteSong(id:",
            "assign(assetID:",
            "resolveDecision(sectionID:",
            "updateNote(",
            "addSection(name:",
            "moveSection(sectionID:",
            "removeSection(sectionID:",
            "pinMaster(songID:",
            "reanalyzeCatalog()"
        ]

        var violations: [String] = []
        let fileManager = FileManager.default

        for sourceRoot in sourceRoots {
            guard let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Could not enumerate production sources at \(sourceRoot.path)")
                return
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift" else { continue }
                let relativePath = fileURL.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )
                guard relativePath != appStatePath else { continue }

                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for pattern in retiredCallPatterns where source.contains(pattern) {
                    violations.append("\(relativePath): \(pattern)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Obsolete legacy AppState bypass APIs regained production callers:\n\(violations.sorted().joined(separator: "\n"))"
        )
    }

    func testObsoleteAppStateBypassesStayRemoved() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appStateURL = repositoryRoot.appendingPathComponent("Sources/ArtistOS/App/AppState.swift")
        let source = try String(contentsOf: appStateURL, encoding: .utf8)

        let removedDefinitions = [
            "func deleteSong(id: UUID)",
            "func assign(assetID: UUID?, sectionID: UUID, songID: UUID)",
            "func setState(_ newState: SectionState, sectionID: UUID, songID: UUID)",
            "func resolveDecision(sectionID: UUID, songID: UUID, winner: UUID)",
            "func updateNote(_ note: String, sectionID: UUID, songID: UUID)",
            "func addSection(name: String, songID: UUID)",
            "func moveSection(sectionID: UUID, songID: UUID, offset: Int)",
            "func removeSection(sectionID: UUID, songID: UUID)",
            "func pinMaster(songID: UUID, assetID: UUID)",
            "func reanalyzeCatalog()"
        ]

        for definition in removedDefinitions {
            XCTAssertFalse(
                source.contains(definition),
                "Retired legacy AppState API was reintroduced: \(definition)"
            )
        }
    }
}
