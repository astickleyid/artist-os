import Foundation
import os

struct ImportProgress: Identifiable {
    let id = UUID()
    var processed: Int = 0
    var total: Int = 0
    var phase: String
    var finishedSummary: String?
    var errorMessage: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSongID: Song.ID?
    @Published var selectedAssetID: Asset.ID?
    @Published var selectedNavigation: NavigationItem = .songs
    @Published var selectedTab: SongTab = .master
    @Published var searchText: String = ""
    @Published var isImportPresented: Bool = false
    @Published var isLogChangePresented: Bool = false
    @Published var importProgress: ImportProgress?
    @Published var catalog: ArtistCatalog
    @Published var watchedFolders: [WatchedFolder] = []

    let audio = AudioPreviewService()

    private let store: CatalogStore
    private let watchService = FolderWatchService()
    private var importTask: Task<Void, Never>?
    private var pendingWatchPaths: Set<String> = []
    private var watchDebounceTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.stickley.artistos", category: "AppState")
    private static let seedKey = "aos.didSeedMockCatalog"

    init(store: CatalogStore = .makeDefault(), seedIfNeeded: Bool = true, enableWatching: Bool = true) {
        self.store = store
        if seedIfNeeded, store.isEmpty, !UserDefaults.standard.bool(forKey: Self.seedKey) {
            store.seed(MockCatalog.make())
            UserDefaults.standard.set(true, forKey: Self.seedKey)
        }
        self.catalog = store.loadCatalog(artistName: "STICK")
        selectedSongID = catalog.songs.first?.id
        watchedFolders = store.watchedFolders()

        if enableWatching {
            watchService.onChanges = { [weak self] paths in
                self?.enqueueWatchedChanges(paths)
            }
            watchService.update(folders: watchedFolders)
            // Catch anything that changed while the app was closed.
            Task { await self.reconcileWatchedFolders() }
        }
    }

    // MARK: - Lookups

    var selectedSong: Song? {
        guard let selectedSongID else { return catalog.songs.first }
        return catalog.songs.first { $0.id == selectedSongID }
    }

    var selectedAsset: Asset? {
        guard let selectedAssetID else { return nil }
        return catalog.assets.first { $0.id == selectedAssetID }
    }

    func asset(id: Asset.ID?) -> Asset? {
        guard let id else { return nil }
        return catalog.assets.first { $0.id == id }
    }

    func assets(for songID: UUID) -> [Asset] {
        catalog.assets
            .filter { $0.songID == songID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func songIndex(_ id: UUID) -> Int? {
        catalog.songs.firstIndex { $0.id == id }
    }

    // MARK: - Song mutations

    func createSong(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let song = ImportService.makeSong(title: trimmed)
        catalog.songs.append(song)
        persist(song)
        record(songID: song.id, target: .song, operation: .structureUpdated,
               summary: "\(trimmed) created with default master slots.")
        selectedSongID = song.id
    }

    func renameSong(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let si = songIndex(id),
              catalog.songs[si].title != trimmed else { return }
        let old = catalog.songs[si].title
        catalog.songs[si].title = trimmed
        persist(catalog.songs[si])
        record(songID: id, target: .song, operation: .structureUpdated,
               summary: "Renamed from \(old) to \(trimmed).")
    }

    func deleteSong(id: UUID) {
        guard let si = songIndex(id) else { return }
        // Stop playback if the active preview belongs to this song.
        if let playingID = audio.playingAssetID,
           catalog.assets.first(where: { $0.id == playingID })?.songID == id {
            audio.stop()
        }
        let title = catalog.songs[si].title
        catalog.songs.remove(at: si)
        catalog.assets.removeAll { $0.songID == id }
        catalog.events.removeAll { $0.songID == id }
        do { try store.delete(songID: id) }
        catch { logger.error("Failed to delete song: \(error.localizedDescription)") }
        if selectedSongID == id {
            selectedSongID = catalog.songs.first?.id
            selectedAssetID = nil
        }
        logger.info("Deleted song \(title)")
    }

    func assign(assetID: UUID?, sectionID: UUID, songID: UUID) {
        guard let si = songIndex(songID),
              let xi = catalog.songs[si].sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        let before = catalog.songs[si].sections[xi].assetID
        guard before != assetID else { return }

        catalog.songs[si].sections[xi].assetID = assetID
        if assetID != nil, catalog.songs[si].sections[xi].state == .open {
            catalog.songs[si].sections[xi].state = .candidate
            catalog.songs[si].sections[xi].confidence = max(catalog.songs[si].sections[xi].confidence, 0.5)
        }
        persistSong(at: si)

        let sectionName = catalog.songs[si].sections[xi].name
        let assetName = asset(id: assetID)?.title ?? "none"
        record(
            songID: songID,
            target: target(forSectionName: sectionName),
            operation: assetID == nil ? .structureUpdated : .sourceSelected,
            before: before,
            after: assetID,
            summary: assetID == nil
                ? "\(sectionName) source cleared."
                : "\(assetName) selected as \(sectionName) source."
        )
    }

    func setState(_ newState: SectionState, sectionID: UUID, songID: UUID) {
        guard let si = songIndex(songID),
              let xi = catalog.songs[si].sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        let old = catalog.songs[si].sections[xi].state
        guard old != newState else { return }

        catalog.songs[si].sections[xi].state = newState
        if newState == .locked {
            catalog.songs[si].sections[xi].confidence = max(catalog.songs[si].sections[xi].confidence, 0.9)
        }
        persistSong(at: si)

        let sectionName = catalog.songs[si].sections[xi].name
        record(
            songID: songID,
            target: target(forSectionName: sectionName),
            operation: operation(forState: newState),
            summary: "\(sectionName) moved from \(old.rawValue) to \(newState.rawValue)."
        )
    }

    /// A/B decision outcome: assigns the winning asset and locks the slot,
    /// producing Source Selected + Approved events in the change log.
    func resolveDecision(sectionID: UUID, songID: UUID, winner: UUID) {
        assign(assetID: winner, sectionID: sectionID, songID: songID)
        setState(.locked, sectionID: sectionID, songID: songID)
    }

    func updateNote(_ note: String, sectionID: UUID, songID: UUID) {
        guard let si = songIndex(songID),
              let xi = catalog.songs[si].sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        catalog.songs[si].sections[xi].note = note
        persistSong(at: si)
    }

    func addSection(name: String, songID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let si = songIndex(songID) else { return }
        let section = MasterSection(
            id: UUID(), name: trimmed, role: "Custom",
            assetID: nil, state: .open, confidence: 0, note: ""
        )
        catalog.songs[si].sections.append(section)
        persistSong(at: si)
        record(songID: songID, target: .song, operation: .structureUpdated,
               summary: "\(trimmed) slot added to master composition.")
    }

    func moveSection(sectionID: UUID, songID: UUID, offset: Int) {
        guard let si = songIndex(songID),
              let xi = catalog.songs[si].sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        let destination = xi + offset
        guard destination >= 0, destination < catalog.songs[si].sections.count else { return }
        catalog.songs[si].sections.swapAt(xi, destination)
        persistSong(at: si)
        let name = catalog.songs[si].sections[destination].name
        record(songID: songID, target: .song, operation: .structureUpdated,
               summary: "\(name) moved to position \(destination + 1).")
    }

    func removeSection(sectionID: UUID, songID: UUID) {
        guard let si = songIndex(songID),
              let xi = catalog.songs[si].sections.firstIndex(where: { $0.id == sectionID })
        else { return }
        let name = catalog.songs[si].sections[xi].name
        catalog.songs[si].sections.remove(at: xi)
        persistSong(at: si)
        record(songID: songID, target: .song, operation: .structureUpdated,
               summary: "\(name) slot removed from master composition.")
    }

    // MARK: - Events

    func logManualEvent(target: EventTarget, operation: EventOperation, summary: String, assetID: UUID?) {
        guard let songID = selectedSong?.id else { return }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        record(
            songID: songID,
            target: target,
            operation: operation,
            after: assetID,
            summary: trimmed.isEmpty ? "\(target.rawValue) \(operation.rawValue.lowercased())." : trimmed
        )
    }

    private func record(
        songID: UUID,
        target: EventTarget,
        operation: EventOperation,
        before: UUID? = nil,
        after: UUID? = nil,
        summary: String,
        confidence: Double = 1.0
    ) {
        let event = CreativeEvent(
            id: UUID(), songID: songID, timestamp: Date(),
            target: target, operation: operation,
            beforeAssetID: before, afterAssetID: after,
            summary: summary, confidence: confidence
        )
        catalog.events.append(event)
        do { try store.append(event: event) }
        catch { logger.error("Failed to persist event: \(error.localizedDescription)") }
    }

    // MARK: - Import

    func importFolder(url: URL) {
        guard importProgress == nil else { return }
        importProgress = ImportProgress(phase: "Scanning \(url.lastPathComponent)…")
        importTask = Task {
            do {
                let outcome = try await ImportService.scan(folder: url) { [weak self] processed, total in
                    Task { @MainActor in
                        self?.importProgress?.processed = processed
                        self?.importProgress?.total = total
                        self?.importProgress?.phase = "Reading audio metadata…"
                    }
                }
                merge(outcome)
                registerWatchedFolder(url: url)
            } catch is CancellationError {
                importProgress?.finishedSummary = "Import cancelled. Nothing was added."
            } catch {
                importProgress?.errorMessage = error.localizedDescription
                importProgress?.finishedSummary = "Import failed."
            }
            importTask = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func merge(_ outcome: ImportOutcome) {
        var newSongs = 0
        var newAssets = 0
        var duplicates = 0
        var existingHashes = Set(catalog.assets.compactMap(\.contentHash))

        for item in outcome.songs {
            let dedup = ImportService.partitionDuplicates(
                assets: item.assets, existingHashes: existingHashes
            )
            duplicates += dedup.duplicateCount
            existingHashes.formUnion(dedup.unique.compactMap(\.contentHash))
            guard !dedup.unique.isEmpty else { continue }
            let targetSongID: UUID
            if let existing = catalog.songs.first(where: {
                $0.title.caseInsensitiveCompare(item.song.title) == .orderedSame
            }) {
                targetSongID = existing.id
            } else {
                catalog.songs.append(item.song)
                persist(item.song)
                targetSongID = item.song.id
                newSongs += 1
                record(songID: targetSongID, target: .song, operation: .imported,
                       summary: "\(item.song.title) imported from local folder.")
            }

            for var asset in dedup.unique {
                asset.songID = targetSongID
                catalog.assets.append(asset)
                do { try store.insert(asset: asset) }
                catch { logger.error("Failed to persist asset: \(error.localizedDescription)") }
                newAssets += 1
                record(songID: targetSongID, target: target(forRole: asset.role),
                       operation: .imported, after: asset.id,
                       summary: "\(asset.originalFilename) imported.")
            }
        }

        if selectedSongID == nil {
            selectedSongID = catalog.songs.first?.id
        }
        importProgress?.finishedSummary =
            "\(newAssets) asset\(newAssets == 1 ? "" : "s") imported · \(newSongs) new song\(newSongs == 1 ? "" : "s") · \(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped · \(outcome.skippedFiles) non-audio file\(outcome.skippedFiles == 1 ? "" : "s") skipped. This folder is now watched for creative activity."
    }

    // MARK: - Watched folders

    func removeWatchedFolder(id: UUID) {
        guard let folder = watchedFolders.first(where: { $0.id == id }) else { return }
        do { try store.deleteWatchedFolder(id: id) }
        catch { logger.error("Failed to remove watched folder: \(error.localizedDescription)") }
        watchedFolders.removeAll { $0.id == id }
        watchService.update(folders: watchedFolders)
        logger.info("Stopped watching \(folder.path)")
    }

    private func registerWatchedFolder(url: URL) {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !watchedFolders.contains(where: { $0.path == path }) else { return }
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let folder = WatchedFolder(id: UUID(), path: path, bookmark: bookmark, addedAt: Date())
        do { try store.save(watchedFolder: folder) }
        catch {
            logger.error("Failed to persist watched folder: \(error.localizedDescription)")
            return
        }
        watchedFolders.append(folder)
        watchService.update(folders: watchedFolders)
    }

    // MARK: - Observed changes (the product thesis: events from real activity)

    private func enqueueWatchedChanges(_ paths: [String]) {
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            if ImportService.audioExtensions.contains(ext) {
                pendingWatchPaths.insert(path)
            }
        }
        guard !pendingWatchPaths.isEmpty else { return }
        watchDebounceTask?.cancel()
        watchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.processWatchedChanges()
        }
    }

    private func processWatchedChanges() async {
        let paths = pendingWatchPaths
        pendingWatchPaths = []
        guard !paths.isEmpty, importProgress == nil else { return }

        var existingHashes = Set(catalog.assets.compactMap(\.contentHash))
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                await observeFile(at: url, existingHashes: &existingHashes)
            } else if let asset = catalog.assets.first(where: { $0.sourcePath == canonicalPath(path) }) {
                observeMissing(asset: asset)
            }
        }
    }

    /// Startup / on-demand diff of watched folders against the catalog, so
    /// activity that happened while the app was closed is still observed.
    func reconcileWatchedFolders() async {
        guard importProgress == nil, !watchedFolders.isEmpty else { return }
        var existingHashes = Set(catalog.assets.compactMap(\.contentHash))

        for folder in watchedFolders {
            let rootURL = folder.resolveURL().resolvingSymlinksInPath().standardizedFileURL
            let didAccess = rootURL.startAccessingSecurityScopedResource()
            defer { if didAccess { rootURL.stopAccessingSecurityScopedResource() } }

            guard let listing = ImportService.listFiles(in: rootURL) else {
                logger.warning("Reconciliation could not read \(folder.path)")
                continue
            }

            for fileURL in listing.audio {
                await observeFile(at: fileURL, existingHashes: &existingHashes)
            }

            let diskPaths = Set(listing.audio.map(\.path))
            let rootPrefix = rootURL.path + "/"
            for asset in catalog.assets {
                guard let sourcePath = asset.sourcePath,
                      sourcePath.hasPrefix(rootPrefix),
                      !diskPaths.contains(sourcePath)
                else { continue }
                observeMissing(asset: asset)
            }
        }
        logger.info("Reconciliation pass complete.")
    }

    /// Handles one on-disk audio file: refreshes a known asset if its
    /// modification time moved, or imports it as a new observed asset.
    private func observeFile(at rawURL: URL, existingHashes: inout Set<String>) async {
        let url = rawURL.resolvingSymlinksInPath().standardizedFileURL
        let path = url.path

        if let index = catalog.assets.firstIndex(where: { $0.sourcePath == path }) {
            let known = catalog.assets[index]
            guard let diskModified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { return }

            if let recorded = known.fileModifiedAt {
                guard abs(diskModified.timeIntervalSince(recorded)) > 1 else { return }
                await refreshAsset(at: index)
                if let songID = known.songID {
                    record(songID: songID, target: target(forRole: known.role),
                           operation: .recordingUpdated, after: known.id,
                           summary: "\(known.originalFilename) changed on disk (observed).",
                           confidence: 0.8)
                }
            } else {
                // Pre-v3 asset: establish a baseline silently instead of
                // spamming change events on first launch after upgrade.
                catalog.assets[index].fileModifiedAt = diskModified
                do { try store.insert(asset: catalog.assets[index]) }
                catch { logger.error("Failed to baseline asset: \(error.localizedDescription)") }
            }
            return
        }

        guard let root = watchedFolders.first(where: {
            let rootPath = canonicalPath($0.path)
            return path.hasPrefix(rootPath + "/") || path == rootPath
        }) else { return }

        var asset = await ImportService.makeAsset(url: url, songID: UUID())
        if let hash = asset.contentHash {
            if existingHashes.contains(hash) { return }
            existingHashes.insert(hash)
        }

        let rootURL = URL(fileURLWithPath: canonicalPath(root.path))
        let group = ImportService.group(for: url, base: rootURL)
        let title = ImportService.titleize(group, stripExtension: false)
        let songID: UUID
        if let existing = catalog.songs.first(where: {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
        }) {
            songID = existing.id
        } else {
            let song = ImportService.makeSong(title: title)
            catalog.songs.append(song)
            persist(song)
            songID = song.id
            record(songID: songID, target: .song, operation: .imported,
                   summary: "\(title) detected in watched folder (observed).", confidence: 0.8)
        }

        asset.songID = songID
        catalog.assets.append(asset)
        do { try store.insert(asset: asset) }
        catch { logger.error("Failed to persist observed asset: \(error.localizedDescription)") }
        record(songID: songID, target: target(forRole: asset.role),
               operation: .imported, after: asset.id,
               summary: "\(asset.originalFilename) appeared in watched folder (observed).",
               confidence: 0.8)
    }

    /// Records a single archived event per asset when its file disappears.
    private func observeMissing(asset: Asset) {
        guard let songID = asset.songID, !hasArchivedEvent(for: asset.id) else { return }
        record(songID: songID, target: target(forRole: asset.role),
               operation: .archived, before: asset.id,
               summary: "\(asset.originalFilename) removed from disk (observed).",
               confidence: 0.8)
    }

    /// Re-reads duration, hash, size, and modification time from disk while
    /// preserving the asset's identity and curated fields.
    private func refreshAsset(at index: Int) async {
        let old = catalog.assets[index]
        guard let path = old.sourcePath else { return }
        var fresh = await ImportService.makeAsset(url: URL(fileURLWithPath: path), songID: old.songID ?? old.id)
        guard index < catalog.assets.count, catalog.assets[index].id == old.id else { return }
        fresh.id = old.id
        fresh.songID = old.songID
        fresh.title = old.title
        fresh.role = old.role
        fresh.createdAt = old.createdAt
        catalog.assets[index] = fresh
        do { try store.insert(asset: fresh) }
        catch { logger.error("Failed to refresh asset: \(error.localizedDescription)") }
    }

    private func hasArchivedEvent(for assetID: UUID) -> Bool {
        catalog.events.contains { $0.operation == .archived && $0.beforeAssetID == assetID }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Persistence helpers

    private func persistSong(at index: Int) {
        recomputeProgress(at: index)
        persist(catalog.songs[index])
    }

    private func persist(_ song: Song) {
        do { try store.upsert(song: song) }
        catch { logger.error("Failed to persist song: \(error.localizedDescription)") }
    }

    private func recomputeProgress(at index: Int) {
        let sections = catalog.songs[index].sections
        guard !sections.isEmpty else {
            catalog.songs[index].progress = 0
            return
        }
        let locked = sections.filter { $0.state == .locked }.count
        catalog.songs[index].progress = Double(locked) / Double(sections.count)
        let undecided = sections.filter { $0.state == .needsDecision }
        catalog.songs[index].risk = undecided.isEmpty
            ? (locked == sections.count ? "Master locked" : "In assembly")
            : "\(undecided.map(\.name).joined(separator: ", ")) decision unresolved"
    }

    // MARK: - Mapping

    private func target(forSectionName name: String) -> EventTarget {
        let lower = name.lowercased()
        if lower.contains("intro") { return .intro }
        if lower.contains("verse") { return .verse }
        if lower.contains("hook") || lower.contains("chorus") { return .hook }
        if lower.contains("bridge") { return .bridge }
        if lower.contains("outro") { return .song }
        return .song
    }

    private func target(forRole role: AssetRole) -> EventTarget {
        switch role {
        case .fullMix: return .mix
        case .leadVocal: return .leadVocal
        case .beat: return .beat
        case .hook: return .hook
        case .bridge: return .bridge
        case .reference: return .song
        }
    }

    private func operation(forState state: SectionState) -> EventOperation {
        switch state {
        case .locked: return .approved
        case .needsDecision: return .needsDecision
        case .candidate: return .candidateAdded
        case .experiment, .open: return .structureUpdated
        }
    }
}

enum NavigationItem: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case timeline = "Timeline"
    case assets = "Assets"
    case dna = "DNA"
    var id: String { rawValue }
}

enum SongTab: String, CaseIterable, Identifiable {
    case master = "Master"
    case changes = "Changes"
    case assets = "Assets"
    var id: String { rawValue }
}
