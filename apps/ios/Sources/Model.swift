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
    private(set) var catalogDecisions: [CreativeDecision] = []
    private(set) var catalogMasterCompositions: [MasterComposition] = []

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

    // MARK: pull application

    private func apply(changes: [SyncLogic.JSONDict]) {
        var catalog = ArtistCatalog(
            artistName: "STICK",
            songs: catalogSongs,
            assets: catalogAssets,
            events: catalogEvents,
            decisions: catalogDecisions,
            masterCompositions: catalogMasterCompositions
        )
        CanonicalSync.apply(changes: changes, to: &catalog)
        catalogSongs = catalog.songs
        catalogAssets = catalog.assets
        catalogEvents = catalog.events
        catalogDecisions = catalog.decisions
        catalogMasterCompositions = catalog.masterCompositions
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
            let canonicalOutput = catalogMasterCompositions
                .first(where: { $0.songID == song.id })?.outputAssetID
            let masterID = canonicalOutput ?? song.masterAssetID
            let master = masterID.flatMap { mid in assets.first(where: { $0.id == mid }) }
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

    private struct Snapshot: Codable {
        var songs: [Song]
        var assets: [Asset]
        var events: [CreativeEvent]
        var decisions: [CreativeDecision]
        var masterCompositions: [MasterComposition]

        init(
            songs: [Song],
            assets: [Asset],
            events: [CreativeEvent],
            decisions: [CreativeDecision] = [],
            masterCompositions: [MasterComposition] = []
        ) {
            self.songs = songs
            self.assets = assets
            self.events = events
            self.decisions = decisions
            self.masterCompositions = masterCompositions
        }

        private enum CodingKeys: String, CodingKey {
            case songs, assets, events, decisions, masterCompositions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            songs = try container.decode([Song].self, forKey: .songs)
            assets = try container.decode([Asset].self, forKey: .assets)
            events = try container.decode([CreativeEvent].self, forKey: .events)
            decisions = try container.decodeIfPresent([CreativeDecision].self, forKey: .decisions) ?? []
            masterCompositions = try container.decodeIfPresent(
                [MasterComposition].self,
                forKey: .masterCompositions
            ) ?? []
        }
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtistOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog-cache.json")
    }
    private func saveCache() {
        let snap = Snapshot(
            songs: catalogSongs,
            assets: catalogAssets,
            events: catalogEvents,
            decisions: catalogDecisions,
            masterCompositions: catalogMasterCompositions
        )
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: cacheURL, options: .atomic) }
    }
    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        catalogSongs = snap.songs
        catalogAssets = snap.assets
        catalogEvents = snap.events
        catalogDecisions = snap.decisions
        catalogMasterCompositions = snap.masterCompositions
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
