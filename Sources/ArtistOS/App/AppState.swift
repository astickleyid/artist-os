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
    let sync: SyncService
    @Published var syncStatus: SyncStatus = .off
    @Published var syncLastError: String?

    private let store: CatalogStore
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
            guard let self else { return }
            if await self.sync.isEnabled {
                self.syncStatus = .on
                try? await self.pullFromCloud()
            }
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
        catalog.songs.flatMap { VersionIntelligence.decisions(for: $0, assets: assets(for: $0.id)) }
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
        markDirty(.event, event.id.uuidString)
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
            for item in items { dirtyEntities[item.kind.rawValue + ":" + item.id] = item } // retry next cycle
        }
    }

    private func pushEntireCatalogToCloud() async throws {
        let changes = catalog.songs.map(SyncLogic.change(forSong:))
            + catalog.assets.map(SyncLogic.change(forAsset:))
            + catalog.events.map(SyncLogic.change(forEvent:))
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
        for change in changes {
            guard let kindRaw = change["kind"] as? String, let kind = SyncLogic.Kind(rawValue: kindRaw),
                  let idString = change["id"] as? String,
                  let updatedAtMs = (change["updatedAt"] as? NSNumber)?.doubleValue
            else { continue }
            let deleted = (change["deleted"] as? Bool) ?? false
            let remoteDate = SyncLogic.date(fromMs: updatedAtMs)

            switch kind {
            case .song:
                guard let uuid = UUID(uuidString: idString) else { continue }
                let idx = catalog.songs.firstIndex(where: { $0.id == uuid })
                if deleted { if let idx { catalog.songs.remove(at: idx) }; continue }
                guard SyncLogic.shouldApplyRemote(updatedAt: updatedAtMs,
                    overLocal: idx.map { catalog.songs[$0].updatedAt } ?? .distantPast) else { continue }
                guard let payload = change["data"] as? SyncLogic.JSONDict,
                      let merged = SyncLogic.mergedSong(payload: payload, updatedAt: remoteDate,
                        existing: idx.map { catalog.songs[$0] })
                else { continue }
                if let idx { catalog.songs[idx] = merged } else { catalog.songs.append(merged) }
                try? store.upsert(song: merged)

            case .asset:
                guard let uuid = UUID(uuidString: idString) else { continue }
                let idx = catalog.assets.firstIndex(where: { $0.id == uuid })
                if deleted { if let idx { catalog.assets.remove(at: idx) }; continue }
                guard SyncLogic.shouldApplyRemote(updatedAt: updatedAtMs,
                    overLocal: idx.map { catalog.assets[$0].updatedAt } ?? .distantPast) else { continue }
                guard let payload = change["data"] as? SyncLogic.JSONDict,
                      let merged = SyncLogic.mergedAsset(payload: payload, updatedAt: remoteDate,
                        existing: idx.map { catalog.assets[$0] })
                else { continue }
                if let idx { catalog.assets[idx] = merged } else { catalog.assets.append(merged) }
                try? store.insert(asset: merged)

            case .event:
                guard let uuid = UUID(uuidString: idString) else { continue }
                if deleted { catalog.events.removeAll { $0.id == uuid }; continue }
                guard !catalog.events.contains(where: { $0.id == uuid }),
                      let payload = change["data"] as? SyncLogic.JSONDict,
                      let songIdString = payload["songId"] as? String, let songID = UUID(uuidString: songIdString),
                      let targetRaw = payload["target"] as? String, let target = EventTarget(rawValue: targetRaw),
                      let opRaw = payload["op"] as? String, let operation = EventOperation(rawValue: opRaw),
                      let summary = payload["summary"] as? String
                else { continue }
                let confidence = (payload["confidence"] as? NSNumber)?.doubleValue ?? 1.0
                let event = CreativeEvent(id: uuid, songID: songID, timestamp: remoteDate, target: target,
                                          operation: operation, beforeAssetID: nil, afterAssetID: nil,
                                          summary: summary, confidence: confidence)
                catalog.events.append(event)
                try? store.append(event: event)
            }
        }
        runDecisionEngine()
    }

    /// Uploads one asset's local audio so it's available on every synced
    /// device. Opt-in per VISION.md — most audio stays local-only.
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

    // MARK: - Decision engine (VISION.md: the app proposes, the artist approves)

    func runDecisionEngine(songIDs: [UUID]? = nil) {
        let ids = songIDs ?? catalog.songs.map(\.id)
        for id in ids {
            guard let si = songIndex(id) else { continue }
            let flags = VersionIntelligence.applyAutoDecisions(
                song: &catalog.songs[si],
                assets: assets(for: id)
            )
            guard !flags.isEmpty else { continue }
            persistSong(at: si)
            for flag in flags {
                record(
                    songID: id,
                    target: VersionIntelligence.slotTarget(forSectionName: flag.sectionName),
                    operation: .needsDecision,
                    summary: "\(flag.sectionName) auto-flagged: \(flag.count) \(flag.role.rawValue.lowercased()) candidates need a call.",
                    confidence: 0.8
                )
            }
        }
    }

    func pinMaster(songID: UUID, assetID: UUID) {
        guard let si = songIndex(songID),
              catalog.songs[si].masterAssetID != assetID,
              let asset = asset(id: assetID)
        else { return }
        catalog.songs[si].masterAssetID = assetID
        persist(catalog.songs[si])
        let versionText = asset.version.map { " (\($0))" } ?? ""
        record(songID: songID, target: .song, operation: .approved,
               summary: "\(asset.title)\(versionText) pinned as current master.")
    }

    // MARK: - Filename re-analysis (fix catalogs imported before intelligence)

    func reanalyzeCatalog() {
        var movedCount = 0, taggedCount = 0
        var touched = Set<UUID>()

        for index in catalog.assets.indices {
            let asset = catalog.assets[index]
            let parsed = VersionIntelligence.parse(asset.originalFilename)
            if asset.version != parsed.label || asset.vOrder != parsed.order {
                catalog.assets[index].version = parsed.label
                catalog.assets[index].vOrder = parsed.order
                taggedCount += 1
                persistAsset(catalog.assets[index])
            }
            guard let homeID = asset.songID,
                  let home = catalog.songs.first(where: { $0.id == homeID }),
                  home.title.caseInsensitiveCompare(parsed.canonical) != .orderedSame,
                  home.sections.allSatisfy({ $0.assetID != asset.id }) // board-assigned never moves
            else { continue }

            let targetID: UUID
            if let existing = catalog.songs.first(where: {
                $0.title.caseInsensitiveCompare(parsed.canonical) == .orderedSame
            }) {
                targetID = existing.id
            } else {
                let song = ImportService.makeSong(title: parsed.canonical)
                catalog.songs.append(song)
                persist(song)
                targetID = song.id
                record(songID: targetID, target: .song, operation: .imported,
                       summary: "\(song.title) created during filename re-analysis.")
            }
            catalog.assets[index].songID = targetID
            persistAsset(catalog.assets[index])
            record(songID: targetID, target: target(forRole: asset.role), operation: .imported,
                   summary: "\(asset.originalFilename) regrouped into song (re-analysis).")
            movedCount += 1
            touched.insert(targetID)
            touched.insert(homeID)
        }

        for id in touched {
            guard let song = catalog.songs.first(where: { $0.id == id }) else { continue }
            if assets(for: id).isEmpty, song.sections.allSatisfy({ $0.assetID == nil }) {
                deleteSong(id: id)
            }
        }
        runDecisionEngine()
        logger.info("Re-analysis: moved \(movedCount), tagged \(taggedCount)")
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

    /// Single choke point for asset writes (mirrors persistAsset in docs/app.js):
    /// stamps updatedAt, keeps catalog.assets authoritative by id, persists.
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
    case changes = "Changes"
    case assets = "Assets"
    var id: String { rawValue }
}
