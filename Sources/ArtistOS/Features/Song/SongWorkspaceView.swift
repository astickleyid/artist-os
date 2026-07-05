import SwiftUI
import ArtistOSCore

struct SongWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @State private var isComparingVersions = false

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
            VStack(alignment: .trailing, spacing: 10) {
                ScoreRing(value: song.qualityScore)
                if state.masterStack(for: song.id).count >= 2 {
                    Button {
                        isComparingVersions = true
                    } label: {
                        Label("Compare Versions", systemImage: "scale.3d")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AOSTheme.blue)
                    .sheet(isPresented: $isComparingVersions) {
                        CompareSheet(song: song, section: nil)
                    }
                }
            }
        }
    }
}

struct AssetGridView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioPreviewService
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
                                if audio.playingAssetID == asset.id {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(AOSTheme.gold)
                                        .symbolEffect(.variableColor.iterative, isActive: audio.isPlaying)
                                }
                            }
                            WaveformView(asset: asset)
                                .frame(height: 26)
                            Text(asset.originalFilename).font(.caption).foregroundStyle(AOSTheme.muted).lineLimit(2)
                            HStack(spacing: 6) {
                                if song.masterAssetID == asset.id {
                                    AOSBadge(text: "★ Master", tint: AOSTheme.gold)
                                } else if assets.count > 1, assets.first?.id == asset.id,
                                          asset.version != nil || asset.vOrder != nil {
                                    AOSBadge(text: "Latest", tint: AOSTheme.green)
                                } else if let version = asset.version {
                                    AOSBadge(text: version, tint: AOSTheme.muted)
                                }
                                AOSBadge(text: asset.role.rawValue, tint: AOSTheme.blue)
                                if let bpm = asset.bpm {
                                    AOSBadge(text: "\(Int(bpm.rounded())) BPM", tint: AOSTheme.muted)
                                }
                                if let key = asset.musicalKey {
                                    AOSBadge(text: key, tint: AOSTheme.muted)
                                }
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
                    .aosHoverable(cornerRadius: 16)
                    .draggable(asset.id.uuidString)
                    .help("Drag onto a master slot to assign")
                }
            }
        }
    }
}
