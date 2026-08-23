import Foundation
import ArtistOSCore
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
    let sync: SyncService
    @Published var syncStatus: SyncStatus = .off
    @Published var syncLastError: String?

    let store: CatalogStore
    private let watchService = FolderWatchService()
    private var importTask: Task<Void, Never>?
    private var pendingWatchPaths: Set<String> = []
    private var watchDebounceTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.stickley.artistos", category: "AppState")
    private static let seedKey = "aos.didSeedMockCatalog"
    private var dirtyEntities: [String: (kind: SyncLogic.Kind, id: String, deleted: Bool)] = [:]
    private var pushDebounceTask: Task<Void, Never>?

    enum SyncStatus { case off, on }

    init(store: CatalogStore = .makeDefault(), seedIfNeeded: Bool = true, enableWatching: Bool = true,
         sync: SyncService = SyncService()) {
        self.store = store
        self.sync = sync
        let shouldResumeSync = sync.wasEnabledAtInitialization
        if seedIfNeeded, store.isEmpty, !UserDefaults.standard.bool(forKey: Self.seedKey) {
            store.seed(MockCatalog.make())
            UserDefaults.standard.set(true, forKey: Self.seedKey)
        }
        self.catalog = store.loadCatalog(artistName: "STICK")
        selectedSongID = catalog.songs.first?.id
        watchedFolders = store.watchedFolders()
        runDecisionEngine()
        queueAnalysis()
        Task { [weak self] in
            guard let self, shouldResumeSync else { return }
            self.syncStatus = .on
            try? await self.pullFromCloud()
        }

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
        VersionIntelligence.sortVersions(catalog.assets.filter { $0.songID == songID })
    }

    func masterStack(for songID: UUID) -> [Asset] {
        VersionIntelligence.masterStack(catalog.assets.filter { $0.songID == songID })
    }

    var pendingDecisions: [VersionIntelligence.Decision] {
        let decisions: [VersionIntelligence.Decision] = catalog.songs.flatMap { song -> [VersionIntelligence.Decision] in
            guard let composition = catalog.masterComposition(for: song.id) else { return [] }
            return VersionIntelligence.decisions(
                for: song,
                masterComposition: composition,
                assets: assets(for: song.id)
            )
        }
        return decisions
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
        markDirty(.event, event.id.uuidString)
    }

    func recordComp(songID: UUID, sources: Int, segments: Int) {
        record(songID: songID, target: .master, operation: .structureUpdated,
               summary: "Comped a new master from \(sources) version\(sources == 1 ? "" : "s") (\(segments) swipe segments).")
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
                persistAsset(asset)
                newAssets += 1
                record(songID: targetSongID, target: target(forRole: asset.role),
                       operation: .imported, after: asset.id,
                       summary: "\(asset.originalFilename) imported.")
            }
        }

        if selectedSongID == nil {
            selectedSongID = catalog.songs.first?.id
        }
        runDecisionEngine(songIDs: outcome.songs.map(\.song.id) + catalog.songs.map(\.id))
        queueAnalysis()
        importProgress?.finishedSummary =
            "\(newAssets) asset\(newAssets == 1 ? "" : "s") imported · \(newSongs) new song\(newSongs == 1 ? "" : "s") · \(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped · \(outcome.skippedFiles) non-audio file\(outcome.skippedFiles == 1 ? "" : "s") skipped. This folder is now watched for creative activity."
    }

    // MARK: - Audio intelligence (BPM + key, queued, persisted)

    private var analysisTask: Task<Void, Never>?

    func queueAnalysis() {
        guard analysisTask == nil else { return }
        analysisTask = Task { [weak self] in
            await self?.drainAnalysis()
            self?.analysisTask = nil
        }
    }

    private func drainAnalysis() async {
        while let index = catalog.assets.firstIndex(where: { $0.analyzedAt == nil && ($0.localURLBookmark != nil || $0.sourcePath != nil) }) {
            let asset = catalog.assets[index]
            var updated = asset
            updated.analyzedAt = Date()
            if let url = AssetFileResolver.url(for: asset) {
                let didAccess = url.startAccessingSecurityScopedResource()
                if let loaded = await AudioAnalysis.loadSamples(url: url) {
                    let result = AudioAnalysis.analyze(loaded.samples, sampleRate: loaded.sampleRate)
                    updated.bpm = result.tempo?.bpm
                    updated.musicalKey = result.key?.name
                }
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            guard let liveIndex = catalog.assets.firstIndex(where: { $0.id == asset.id }) else { continue }
            catalog.assets[liveIndex] = updated
            persistAsset(updated)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    // MARK: - Sync (Cloudflare; VISION.md: metadata-first, audio opt-in)

    private func markDirty(_ kind: SyncLogic.Kind, _ id: String, deleted: Bool = false) {
        dirtyEntities[kind.rawValue + ":" + id] = (kind, id, deleted)
        guard syncStatus == .on else { return }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushDirtyToCloud()
        }
    }

    private func pushDirtyToCloud() async {
        guard syncStatus == .on, !dirtyEntities.isEmpty else { return }
        let items = Array(dirtyEntities.values)
        dirtyEntities.removeAll()
        let changes: [SyncLogic.JSONDict] = items.compactMap { item in
            if item.deleted { return SyncLogic.tombstone(kind: item.kind, id: item.id) }
            switch item.kind {
            case .song:
                guard let uuid = UUID(uuidString: item.id), let s = catalog.songs.first(where: { $0.id == uuid })
                else { return nil }
                return SyncLogic.change(forSong: s)
            case .asset:
                guard let uuid = UUID(uuidString: item.id), let a = catalog.assets.first(where: { $0.id == uuid })
                else { return nil }
                return SyncLogic.change(forAsset: a)
            case .event:
                guard let uuid = UUID(uuidString: item.id), let e = catalog.events.first(where: { $0.id == uuid })
                else { return nil }
                return SyncLogic.change(forEvent: e)
            }
        }
        guard !changes.isEmpty else { return }
        do {
            _ = try await sync.push(changes: changes)
            syncLastError = nil
        } catch {
            syncLastError = error.localizedDescription
            for item in items { dirtyEntities[item.kind.rawValue + ":" + item.id] = item }
        }
    }

    private func pushEntireCatalogToCloud() async throws {
        let changes = catalog.songs.map(SyncLogic.change(forSong:))
            + catalog.assets.map(SyncLogic.change(forAsset:))
            + catalog.events.map(SyncLogic.change(forEvent:))
            + catalog.decisions.map(SyncLogic.change(forDecision:))
            + catalog.masterCompositions.map(SyncLogic.change(forMasterComposition:))
        _ = try await sync.push(changes: changes)
    }

    func enableSync() async {
        do {
            _ = try await sync.enableSync()
            syncStatus = .on
            syncLastError = nil
            try await pushEntireCatalogToCloud()
        } catch {
            syncLastError = error.localizedDescription
        }
    }

    func startDeviceLink() async throws -> (code: String, expiresInSeconds: Int) {
        if syncStatus != .on { await enableSync() }
        return try await sync.linkStart()
    }

    func claimDeviceLink(code: String) async {
        do {
            _ = try await sync.linkClaim(code: code)
            syncStatus = .on
            syncLastError = nil
            try await pullFromCloud()
        } catch {
            syncLastError = error.localizedDescription
        }
    }

    func pullFromCloud() async throws {
        let changes = try await sync.pullAll()
        _ = try applyCanonicalCloudChanges(changes)
    }

    func uploadAssetToCloud(_ assetID: UUID) async {
        guard let index = catalog.assets.firstIndex(where: { $0.id == assetID }),
              let url = AssetFileResolver.url(for: catalog.assets[index])
        else { syncLastError = "No local audio to upload."; return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if syncStatus != .on { await enableSync() }
            try await sync.uploadBlob(assetID: assetID.uuidString, data: data,
                                       contentType: "audio/\(url.pathExtension)")
            catalog.assets[index].cloudKey = assetID.uuidString
            persistAsset(catalog.assets[index])
            syncLastError = nil
        } catch {
            syncLastError = error.localizedDescription
        }
    }

    // MARK: - Decision engine

    func runDecisionEngine(songIDs: [UUID]? = nil) {
        let ids = songIDs ?? catalog.songs.map(\.id)
        for id in ids {
            guard let si = songIndex(id) else { continue }

            var composition = catalog.masterCompositions.first(where: { $0.songID == id })
                ?? MasterComposition.projected(from: catalog.songs[si])
            let flags = VersionIntelligence.applyAutoDecisions(
                masterComposition: &composition,
                assets: assets(for: id)
            )
            guard !flags.isEmpty else { continue }

            let timestamp = Date()
            composition.updatedAt = timestamp
            var updatedSong = catalog.songs[si]

            let locked = composition.sections.filter { $0.state == .locked }.count
            updatedSong.progress = composition.sections.isEmpty
                ? 0
                : Double(locked) / Double(composition.sections.count)
            let unresolved = composition.sections.filter { $0.state == .needsDecision }
            updatedSong.risk = unresolved.isEmpty
                ? (locked == composition.sections.count && !composition.sections.isEmpty ? "Master locked" : "In assembly")
                : "\(unresolved.map(\.name).joined(separator: ", ")) decision unresolved"
            updatedSong.updatedAt = timestamp

            let events = flags.map { flag in
                CreativeEvent(
                    id: UUID(), songID: id, timestamp: timestamp,
                    target: VersionIntelligence.slotTarget(forSectionName: flag.sectionName),
                    operation: .needsDecision,
                    beforeAssetID: nil, afterAssetID: nil,
                    summary: "\(flag.sectionName) auto-flagged: \(flag.count) \(flag.role.rawValue.lowercased()) candidates need a call.",
                    confidence: 0.8
                )
            }
            let syncChanges: [SyncLogic.JSONDict] = syncStatus == .on
                ? [SyncLogic.change(forSong: updatedSong)]
                    + events.map(SyncLogic.change(forEvent:))
                    + [SyncLogic.change(forMasterComposition: composition)]
                : []

            do {
                try store.commitAutoDecisionEscalation(
                    song: updatedSong,
                    events: events,
                    masterComposition: composition,
                    syncChanges: syncChanges
                )
            } catch {
                logger.error("Auto-decision escalation transaction failed: \(error.localizedDescription)")
                continue
            }

            catalog.songs[si] = updatedSong
            catalog.events.append(contentsOf: events)
            catalog.setMasterComposition(composition)
            if !syncChanges.isEmpty {
                resumeCanonicalSyncOutbox()
            }
        }
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

    // MARK: - Observed changes

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
                catalog.assets[index].fileModifiedAt = diskModified
                persistAsset(catalog.assets[index])
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
        persistAsset(asset)
        record(songID: songID, target: target(forRole: asset.role),
               operation: .imported, after: asset.id,
               summary: "\(asset.originalFilename) appeared in watched folder (observed).",
               confidence: 0.8)
        runDecisionEngine(songIDs: [songID])
        queueAnalysis()
    }

    private func observeMissing(asset: Asset) {
        guard let songID = asset.songID, !hasArchivedEvent(for: asset.id) else { return }
        record(songID: songID, target: target(forRole: asset.role),
               operation: .archived, before: asset.id,
               summary: "\(asset.originalFilename) removed from disk (observed).",
               confidence: 0.8)
    }

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
        fresh.analyzedAt = nil
        catalog.assets[index] = fresh
        persistAsset(fresh)
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
        var toStore = song
        toStore.updatedAt = Date()
        if let idx = catalog.songs.firstIndex(where: { $0.id == song.id }) {
            catalog.songs[idx] = toStore
        }
        do { try store.upsert(song: toStore) }
        catch { logger.error("Failed to persist song: \(error.localizedDescription)") }
        markDirty(.song, toStore.id.uuidString)
    }

    private func persistAsset(_ asset: Asset) {
        var toStore = asset
        toStore.updatedAt = Date()
        if let idx = catalog.assets.firstIndex(where: { $0.id == asset.id }) {
            catalog.assets[idx] = toStore
        }
        do { try store.insert(asset: toStore) }
        catch { logger.error("Failed to persist asset: \(error.localizedDescription)") }
        markDirty(.asset, toStore.id.uuidString)
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
    case comp = "Comp"
    case changes = "Changes"
    case assets = "Assets"
    var id: String { rawValue }
}
