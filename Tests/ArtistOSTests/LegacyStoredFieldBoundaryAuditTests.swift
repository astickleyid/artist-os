import Foundation
import XCTest

final class LegacyStoredFieldBoundaryAuditTests: XCTestCase {
    func testLegacySourceMirrorWritesStayInsideCompatibilityBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            repositoryRoot.appendingPathComponent("Sources/ArtistOS", isDirectory: true),
            repositoryRoot.appendingPathComponent("Sources/ArtistOSCore", isDirectory: true)
        ]

        // These files are the only remaining native compatibility boundary for
        // persisted legacy source/master fields. Artist-facing features and new
        // canonical editors must not start writing these mirrors again.
        let allowedWriteFiles: Set<String> = [
            "Sources/ArtistOS/App/AppState.swift",
            "Sources/ArtistOS/Persistence/Records.swift",
            "Sources/ArtistOSCore/Models.swift",
            "Sources/ArtistOSCore/SyncLogic.swift"
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
                let source = try String(contentsOf: fileURL, encoding: .utf8)

                let hasLegacyMasterWrite = source
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .contains { $0.contains("masterAssetID =") }
                let hasLegacySectionSourceWrite = source
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .contains { line in
                        line.contains(".sections[") && line.contains(".assetID =")
                    }

                guard hasLegacyMasterWrite || hasLegacySectionSourceWrite else { continue }
                if !allowedWriteFiles.contains(relativePath) {
                    violations.append(relativePath)
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Legacy source/master mirror writes escaped the compatibility boundary:\n\(violations.sorted().joined(separator: "\n"))"
        )
    }

    func testCanonicalFeatureFilesDoNotWriteLegacySourceMirrors() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let featureRoot = repositoryRoot.appendingPathComponent("Sources/ArtistOS/Features", isDirectory: true)
        let appExtensions = repositoryRoot.appendingPathComponent("Sources/ArtistOS/App", isDirectory: true)
        let fileManager = FileManager.default

        var violations: [String] = []
        for root in [featureRoot, appExtensions] {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "swift",
                      fileURL.lastPathComponent != "AppState.swift" else { continue }
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
                let writesLegacyMaster = lines.contains { $0.contains("masterAssetID =") }
                let writesLegacySectionSource = lines.contains { line in
                    line.contains(".sections[") && line.contains(".assetID =")
                }
                if writesLegacyMaster || writesLegacySectionSource {
                    violations.append(fileURL.path.replacingOccurrences(
                        of: repositoryRoot.path + "/",
                        with: ""
                    ))
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Canonical feature/editor code resumed writing retired Song source mirrors:\n\(violations.sorted().joined(separator: "\n"))"
        )
    }
}
