import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSongID: Song.ID?
    @Published var selectedAssetID: Asset.ID?
    @Published var selectedNavigation: NavigationItem = .songs
    @Published var selectedTab: SongTab = .master
    @Published var searchText: String = ""
    @Published var isImportPresented: Bool = false
    @Published var catalog: ArtistCatalog = MockCatalog.make()

    init() {
        selectedSongID = catalog.songs.first?.id
    }

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
