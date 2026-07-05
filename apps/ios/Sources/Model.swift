import Foundation
import ArtistOSCore

// Display-layer types the Home rows render. Derived from the REAL catalog now.
struct MobileSong: Identifiable, Equatable {
    let id: String; var title: String; var status: String
    var versionCount: Int; var lastTouch: Date; var bpm: Int?; var key: String?
}
struct MobileDecision: Identifiable, Equatable {
    enum Kind { case competing, master }
    let id: String; var kind: Kind; var songTitle: String; var detail: String
}
struct MobileEvent: Identifiable, Equatable {
    let id: String; var summary: String; var songTitle: String?; var at: Date
}

enum LinkState: Equatable { case notLinked, linking, linked, failed(String) }

/// The companion's real store: links this phone to the artist's account with a
/// device code, pulls the catalog from the live sync Worker via the SAME
/// SyncLogic the Mac app uses, runs the shared decision engine, and caches a
/// snapshot to disk so the app opens instantly offline.
@MainActor
final class CompanionStore: ObservableObject {
    @Published var songs: [MobileSong] = []
    @Published var decisions: [MobileDecision] = []
    @Published var recent: [MobileEvent] = []
    @Published var linkState: LinkState = .notLinked
    @Published var refreshing = false

    // TODO(security): SyncService stores credentials in UserDefaults today (on
    // both platforms). Harden to Keychain in a dedicated pass — tracked work,
    // not silently skipped.
    private let sync = SyncService()

    private(set) var catalogSongs: [Song] = []
    private(set) var catalogAssets: [Asset] = []
    private(set) var catalogEvents: [CreativeEvent] = []

    // MARK: lifecycle

    func bootstrap() async {
        loadCache()
        rebuildDisplay()
        if await sync.isEnabled {
            linkState = .linked
            await refresh()
        }
    }

    func link(code: String) async {
        linkState = .linking
        do {
            _ = try await sync.linkClaim(code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            linkState = .linked
            await refresh()
        } catch {
            linkState = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard await sync.isEnabled else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let changes = try await sync.pullAll()
            apply(changes: changes)
            rebuildDisplay()
            saveCache()
        } catch {
            // keep showing the cached catalog; surface nothing scary on a
            // transient network failure
        }
    }

    // MARK: pull application (mirrors AppState.pullFromCloud exactly)

    private func apply(changes: [SyncLogic.JSONDict]) {
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
                let idx = catalogSongs.firstIndex(where: { $0.id == uuid })
                if deleted { if let idx { catalogSongs.remove(at: idx) }; continue }
                guard SyncLogic.shouldApplyRemote(updatedAt: updatedAtMs,
                    overLocal: idx.map { catalogSongs[$0].updatedAt } ?? .distantPast) else { continue }
                guard let payload = change["data"] as? SyncLogic.JSONDict,
                      let merged = SyncLogic.mergedSong(payload: payload, updatedAt: remoteDate,
                        existing: idx.map { catalogSongs[$0] })
                else { continue }
                if let idx { catalogSongs[idx] = merged } else { catalogSongs.append(merged) }

            case .asset:
                guard let uuid = UUID(uuidString: idString) else { continue }
                let idx = catalogAssets.firstIndex(where: { $0.id == uuid })
                if deleted { if let idx { catalogAssets.remove(at: idx) }; continue }
                guard SyncLogic.shouldApplyRemote(updatedAt: updatedAtMs,
                    overLocal: idx.map { catalogAssets[$0].updatedAt } ?? .distantPast) else { continue }
                guard let payload = change["data"] as? SyncLogic.JSONDict,
                      let merged = SyncLogic.mergedAsset(payload: payload, updatedAt: remoteDate,
                        existing: idx.map { catalogAssets[$0] })
                else { continue }
                if let idx { catalogAssets[idx] = merged } else { catalogAssets.append(merged) }

            case .event:
                guard let uuid = UUID(uuidString: idString) else { continue }
                if deleted { catalogEvents.removeAll { $0.id == uuid }; continue }
                guard !catalogEvents.contains(where: { $0.id == uuid }),
                      let payload = change["data"] as? SyncLogic.JSONDict,
                      let songIdString = payload["songId"] as? String, let songID = UUID(uuidString: songIdString),
                      let targetRaw = payload["target"] as? String, let target = EventTarget(rawValue: targetRaw),
                      let opRaw = payload["op"] as? String, let operation = EventOperation(rawValue: opRaw),
                      let summary = payload["summary"] as? String
                else { continue }
                let confidence = (payload["confidence"] as? NSNumber)?.doubleValue ?? 1.0
                catalogEvents.append(CreativeEvent(id: uuid, songID: songID, timestamp: remoteDate,
                    target: target, operation: operation, beforeAssetID: nil, afterAssetID: nil,
                    summary: summary, confidence: confidence))
            }
        }
    }

    // MARK: display derivation (shared decision engine, triage ordering)

    private func rebuildDisplay() {
        let assetsBySong = Dictionary(grouping: catalogAssets, by: { $0.songID })

        var allDecisions: [MobileDecision] = []
        for song in catalogSongs {
            let assets = assetsBySong[song.id] ?? []
            for d in VersionIntelligence.decisions(for: song, assets: assets) {
                allDecisions.append(MobileDecision(
                    id: d.id, kind: d.kind == .master ? .master : .competing,
                    songTitle: song.title, detail: d.detail))
            }
        }
        decisions = allDecisions

        recent = catalogEvents
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
            .map { e in
                MobileEvent(id: e.id.uuidString, summary: e.summary,
                            songTitle: catalogSongs.first(where: { $0.id == e.songID })?.title,
                            at: e.timestamp)
            }

        let decisionSongTitles = Set(allDecisions.map(\.songTitle))
        songs = catalogSongs.map { song -> MobileSong in
            let assets = assetsBySong[song.id] ?? []
            let stack = VersionIntelligence.versionStack(assets)
            let lastEvent = catalogEvents.filter { $0.songID == song.id }.map(\.timestamp).max()
            let lastAsset = assets.map(\.updatedAt).max()
            let master = song.masterAssetID.flatMap { mid in assets.first(where: { $0.id == mid }) }
            let anyAnalyzed = master ?? assets.first(where: { $0.bpm != nil })
            return MobileSong(
                id: song.id.uuidString, title: song.title, status: song.status.rawValue,
                versionCount: max(stack.count, assets.isEmpty ? 0 : 1),
                lastTouch: [lastEvent, lastAsset].compactMap { $0 }.max() ?? song.updatedAt,
                bpm: anyAnalyzed?.bpm.map { Int($0.rounded()) },
                key: anyAnalyzed?.musicalKey)
        }
        .sorted { a, b in
            let an = decisionSongTitles.contains(a.title), bn = decisionSongTitles.contains(b.title)
            if an != bn { return an }
            return a.lastTouch > b.lastTouch
        }
    }

    // MARK: offline cache (open instantly, refresh in background)

    private struct Snapshot: Codable { var songs: [Song]; var assets: [Asset]; var events: [CreativeEvent] }
    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtistOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog-cache.json")
    }
    private func saveCache() {
        let snap = Snapshot(songs: catalogSongs, assets: catalogAssets, events: catalogEvents)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: cacheURL, options: .atomic) }
    }
    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        catalogSongs = snap.songs; catalogAssets = snap.assets; catalogEvents = snap.events
    }
}

extension Date {
    var agoShort: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
