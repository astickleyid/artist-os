import SwiftUI
import UniformTypeIdentifiers

struct ArtistOSShellView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } content: {
            VStack(spacing: 0) {
                CommandBarView()
                SongListColumn()
            }
            .background(AOSTheme.background)
            .navigationSplitViewColumnWidth(min: 320, ideal: 370, max: 440)
        } detail: {
            HStack(spacing: 0) {
                SongWorkspaceView()
                Divider().overlay(AOSTheme.line)
                InspectorView()
                    .frame(width: 310)
            }
            .background(AOSTheme.background)
        }
        .preferredColorScheme(.dark)
        .tint(AOSTheme.gold)
        .fileImporter(
            isPresented: $state.isImportPresented,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.importFolder(url: url)
            }
        }
        .sheet(item: $state.importProgress) { _ in
            ImportProgressSheet()
        }
        .sheet(isPresented: $state.isLogChangePresented) {
            LogChangeSheet()
        }
    }
}

struct SongListColumn: View {
    @EnvironmentObject private var state: AppState

    var filteredSongs: [Song] {
        guard !state.searchText.isEmpty else { return state.catalog.songs }
        return state.catalog.songs.filter { $0.title.localizedCaseInsensitiveContains(state.searchText) || $0.era.localizedCaseInsensitiveContains(state.searchText) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredSongs) { song in
                    Button {
                        state.selectedSongID = song.id
                    } label: {
                        SongRow(song: song, isSelected: song.id == state.selectedSongID)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }
}

struct SongRow: View {
    let song: Song
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AOSTheme.text)
                    Text("\(song.era) · \(song.sections.count) master slots")
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                }
                Spacer()
                AOSBadge(text: song.status.rawValue)
            }
            AOSProgressBar(value: song.progress)
        }
        .padding(14)
        .background(isSelected ? AOSTheme.gold.opacity(0.10) : AOSTheme.panel.opacity(0.70), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isSelected ? AOSTheme.gold.opacity(0.32) : AOSTheme.line, lineWidth: 1))
    }
}
