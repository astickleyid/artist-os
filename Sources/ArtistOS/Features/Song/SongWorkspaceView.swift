import SwiftUI

struct SongWorkspaceView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let song = state.selectedSong {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(song)
                        Picker("", selection: $state.selectedTab) {
                            ForEach(SongTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)

                        switch state.selectedTab {
                        case .master:
                            MasterCompositionView(song: song)
                        case .changes:
                            CreativeTimelineView(song: song)
                        case .assets:
                            AssetGridView(song: song)
                        }
                    }
                    .padding(22)
                }
            } else {
                ContentUnavailableView("No Song Selected", systemImage: "music.note.list")
            }
        }
    }

    private func header(_ song: Song) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Current Song")
                    .font(.caption.weight(.black))
                    .foregroundStyle(AOSTheme.gold)
                    .textCase(.uppercase)
                Text(song.title)
                    .font(.system(size: 40, weight: .black, design: .default))
                    .tracking(-1.6)
                Text("\(song.era) · \(song.status.rawValue)")
                    .foregroundStyle(AOSTheme.muted)
            }
            Spacer()
            ScoreRing(value: song.qualityScore)
        }
    }
}

struct AssetGridView: View {
    @EnvironmentObject private var state: AppState
    let song: Song

    var assets: [Asset] {
        let owned = state.assets(for: song.id)
        if !owned.isEmpty { return owned }
        return song.sections.compactMap { state.asset(id: $0.assetID) }
    }

    var body: some View {
        if assets.isEmpty {
            Text("No assets yet. Import a folder to attach recordings, beats, and mixes to this song.")
                .font(.caption)
                .foregroundStyle(AOSTheme.muted)
                .padding(14)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(assets) { asset in
                    Button {
                        state.selectedAssetID = asset.id
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                PlayButton(asset: asset)
                                Text(asset.title).font(.headline.weight(.bold)).lineLimit(1)
                            }
                            Text(asset.originalFilename).font(.caption).foregroundStyle(AOSTheme.muted).lineLimit(2)
                            HStack(spacing: 6) {
                                AOSBadge(text: asset.role.rawValue, tint: AOSTheme.blue)
                                if let format = asset.format, !format.isEmpty {
                                    AOSBadge(text: format, tint: AOSTheme.muted)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .aosPanel(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
