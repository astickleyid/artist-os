import Foundation
import AVFoundation
import CoreMedia
import CryptoKit

struct ImportedSong {
    var song: Song
    var assets: [Asset]
}

struct ImportOutcome {
    var songs: [ImportedSong]
    var skippedFiles: Int
}

enum ImportError: Error, LocalizedError {
    case cannotEnumerate

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate: return "The folder could not be read."
        }
    }
}

struct DedupResult {
    var unique: [Asset]
    var duplicateCount: Int
}

/// Scans a local folder into songs + assets.
/// Grouping rule: each top-level subfolder becomes one song (nested files roll up);
/// loose audio files at the root become a song named after the folder itself.
enum ImportService {
    static let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "m4a", "flac", "caf", "ogg", "aac"
    ]

    // MARK: - Heuristics

    static func inferRole(filename: String) -> AssetRole {
        let name = filename.lowercased()
        if name.contains("beat") || name.contains("instrumental") || name.contains("inst.") {
            return .beat
        }
        if name.contains("hook") || name.contains("chorus") {
            return .hook
        }
        if name.contains("bridge") {
            return .bridge
        }
        if name.contains("vocal") || name.contains("vox") || name.contains("acapella") || name.contains("verse") {
            return .leadVocal
        }
        if name.contains("ref") {
            return .reference
        }
        return .fullMix
    }

    static func titleize(_ raw: String, stripExtension: Bool = true) -> String {
        var base = raw
        if stripExtension {
            base = (raw as NSString).deletingPathExtension
        }
        let cleaned = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let collapsed = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? raw : collapsed
    }

    static func defaultSections() -> [MasterSection] {
        [
            MasterSection(id: UUID(), name: "Intro", role: "Atmosphere", assetID: nil, state: .open, confidence: 0, note: ""),
            MasterSection(id: UUID(), name: "Verse 1", role: "Lead vocal", assetID: nil, state: .open, confidence: 0, note: ""),
            MasterSection(id: UUID(), name: "Hook", role: "Melody", assetID: nil, state: .open, confidence: 0, note: ""),
            MasterSection(id: UUID(), name: "Bridge", role: "Alt pocket", assetID: nil, state: .open, confidence: 0, note: ""),
            MasterSection(id: UUID(), name: "Outro", role: "Space", assetID: nil, state: .open, confidence: 0, note: "")
        ]
    }

    static func makeSong(title: String) -> Song {
        Song(
            id: UUID(),
            title: title,
            era: "Imported",
            status: .assembling,
            progress: 0,
            qualityScore: 0.5,
            risk: "No structure decisions yet",
            sections: defaultSections()
        )
    }

    // MARK: - Scan

    static func scan(
        folder: URL,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> ImportOutcome {
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if didAccess { folder.stopAccessingSecurityScopedResource() }
        }

        let base = folder.resolvingSymlinksInPath().standardizedFileURL

        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.cannotEnumerate
        }

        var audioFiles: [(url: URL, group: String)] = []
        var skipped = 0

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }

            guard audioExtensions.contains(url.pathExtension.lowercased()) else {
                skipped += 1
                continue
            }

            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            audioFiles.append((resolved, group(for: resolved, base: base)))
        }

        let total = audioFiles.count
        var processed = 0
        var songsByGroup: [String: ImportedSong] = [:]

        for entry in audioFiles {
            try Task.checkCancellation()
            if songsByGroup[entry.group] == nil {
                songsByGroup[entry.group] = ImportedSong(
                    song: makeSong(title: titleize(entry.group, stripExtension: false)),
                    assets: []
                )
            }
            let songID = songsByGroup[entry.group]!.song.id
            let asset = await makeAsset(url: entry.url, songID: songID)
            songsByGroup[entry.group]!.assets.append(asset)
            processed += 1
            progress(processed, total)
        }

        return ImportOutcome(
            songs: songsByGroup.keys.sorted().compactMap { songsByGroup[$0] },
            skippedFiles: skipped
        )
    }

    /// Song-grouping rule shared by import scan and the folder watcher:
    /// first path component under the base folder, else the base folder itself.
    static func group(for url: URL, base: URL) -> String {
        let baseComponents = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let fileComponents = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count else {
            return base.lastPathComponent
        }
        let relative = Array(fileComponents.dropFirst(baseComponents.count))
        return relative.count > 1 ? relative[0] : base.lastPathComponent
    }

    /// Streaming SHA-256 of file contents, used for duplicate detection.
    static func contentHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Splits scanned assets into unique vs. already-in-catalog by content hash.
    /// Assets without a hash (unreadable files) always pass through as unique.
    static func partitionDuplicates(assets: [Asset], existingHashes: Set<String>) -> DedupResult {
        var seen = existingHashes
        var unique: [Asset] = []
        var duplicates = 0
        for asset in assets {
            if let hash = asset.contentHash {
                if seen.contains(hash) {
                    duplicates += 1
                    continue
                }
                seen.insert(hash)
            }
            unique.append(asset)
        }
        return DedupResult(unique: unique, duplicateCount: duplicates)
    }

    // MARK: - Metadata

    static func makeAsset(url: URL, songID: UUID) async -> Asset {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])

        var duration: TimeInterval?
        var sampleRate: Double?
        var channels: Int?

        // Best-effort: unreadable/corrupt files still import with nil audio metadata.
        let avAsset = AVURLAsset(url: url)
        if let cmDuration = try? await avAsset.load(.duration), cmDuration.seconds.isFinite {
            duration = cmDuration.seconds
        }
        if let track = try? await avAsset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            sampleRate = asbd.pointee.mSampleRate
            channels = Int(asbd.pointee.mChannelsPerFrame)
        }

        let hash = contentHash(of: url)

        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return Asset(
            id: UUID(),
            title: titleize(url.lastPathComponent),
            originalFilename: url.lastPathComponent,
            role: inferRole(filename: url.lastPathComponent),
            createdAt: values?.creationDate ?? Date(),
            duration: duration,
            localURLBookmark: bookmark,
            songID: songID,
            sourcePath: url.path,
            fileSize: (values?.fileSize).map(Int64.init),
            format: url.pathExtension.uppercased(),
            sampleRate: sampleRate,
            channels: channels,
            contentHash: hash
        )
    }
}
