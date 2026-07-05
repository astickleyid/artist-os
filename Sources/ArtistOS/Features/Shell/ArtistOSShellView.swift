import SwiftUI
import ArtistOSCore
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
                switch state.selectedNavigation {
                case .songs:
                    SongListColumn()
                case .timeline:
                    GlobalTimelineColumn()
                case .assets:
                    GlobalAssetsColumn()
                case .dna:
                    DNAPlaceholderColumn()
                }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar()
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

    @State private var renamingSong: Song?
    @State private var renameDraft = ""
    @State private var deletingSong: Song?

    var filteredSongs: [Song] {
        guard !state.searchText.isEmpty else { return state.catalog.songs }
        return state.catalog.songs.filter { $0.title.localizedCaseInsensitiveContains(state.searchText) || $0.era.localizedCaseInsensitiveContains(state.searchText) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                decideInbox
                if filteredSongs.isEmpty {
                    emptyState
                }
                ForEach(filteredSongs) { song in
                    Button {
                        state.selectedSongID = song.id
                    } label: {
                        SongRow(song: song, isSelected: song.id == state.selectedSongID)
                    }
                    .buttonStyle(.plain)
                    .aosHoverable(cornerRadius: 16)
                    .contextMenu {
                        Button("Rename…") {
                            renameDraft = song.title
                            renamingSong = song
                        }
                        Divider()
                        Button("Delete Song…", role: .destructive) {
                            deletingSong = song
                        }
                    }
                }
            }
            .padding(14)
            .animation(.snappy(duration: 0.25), value: filteredSongs.map(\.id))
        }
        .alert("Rename Song", isPresented: Binding(
            get: { renamingSong != nil },
            set: { if !$0 { renamingSong = nil } }
        )) {
            TextField("Title", text: $renameDraft)
            Button("Rename") {
                if let song = renamingSong {
                    state.renameSong(id: song.id, to: renameDraft)
                }
                renamingSong = nil
            }
            Button("Cancel", role: .cancel) { renamingSong = nil }
        }
        .confirmationDialog(
            "Delete \u{201C}\(deletingSong?.title ?? "")\u{201D}?",
            isPresented: Binding(
                get: { deletingSong != nil },
                set: { if !$0 { deletingSong = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Song and Its Assets", role: .destructive) {
                if let song = deletingSong {
                    state.deleteSong(id: song.id)
                }
                deletingSong = nil
            }
            Button("Cancel", role: .cancel) { deletingSong = nil }
        } message: {
            Text("Removes the song, its assets, and its change history from the catalog. Files on disk are not touched.")
        }
    }

    @ViewBuilder
    private var decideInbox: some View {
        let decisions = state.pendingDecisions
        if !decisions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Decide · \(decisions.count)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AOSTheme.gold)
                    .textCase(.uppercase)
                ForEach(decisions) { decision in
                    Button {
                        state.selectedSongID = decision.songID
                        state.selectedTab = decision.kind == .slot ? .master : .assets
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "scale.3d")
                                .foregroundStyle(AOSTheme.gold)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(decision.title)
                                    .font(.subheadline.weight(.bold))
                                    .lineLimit(1)
                                Text(decision.detail)
                                    .font(.caption)
                                    .foregroundStyle(AOSTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            AOSBadge(text: "A/B", tint: AOSTheme.gold)
                        }
                        .padding(12)
                        .background(AOSTheme.gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AOSTheme.gold.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Divider().overlay(AOSTheme.line).padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: state.searchText.isEmpty ? "music.note.list" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(AOSTheme.muted)
            Text(state.searchText.isEmpty ? "No songs yet" : "No matches")
                .font(.headline.weight(.bold))
            if state.searchText.isEmpty {
                Text("Import a career folder or create a song to get started.")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
                    .multilineTextAlignment(.center)
                Button("Import Career Folder…") {
                    state.isImportPresented = true
                }
                .buttonStyle(.borderedProminent)
                .tint(AOSTheme.gold)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
