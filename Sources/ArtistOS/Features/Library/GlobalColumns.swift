import SwiftUI

/// All creative events across the catalog, newest first (Timeline nav item).
struct GlobalTimelineColumn: View {
    @EnvironmentObject private var state: AppState

    private var events: [CreativeEvent] {
        let all = state.catalog.events.sorted { $0.timestamp > $1.timestamp }
        guard !state.searchText.isEmpty else { return all }
        return all.filter {
            $0.summary.localizedCaseInsensitiveContains(state.searchText)
                || $0.target.rawValue.localizedCaseInsensitiveContains(state.searchText)
                || $0.operation.rawValue.localizedCaseInsensitiveContains(state.searchText)
        }
    }

    private func songTitle(for event: CreativeEvent) -> String {
        state.catalog.songs.first { $0.id == event.songID }?.title ?? "Unknown Song"
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if events.isEmpty {
                    Text("No creative events yet. Import a folder or edit a master composition to start the record.")
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                        .padding(14)
                }
                ForEach(events) { event in
                    Button {
                        state.selectedSongID = event.songID
                        state.selectedTab = .changes
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(songTitle(for: event))
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(AOSTheme.gold)
                                    .lineLimit(1)
                                Spacer()
                                Text(AOSTime.ago(event.timestamp))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(AOSTheme.muted)
                                    .help(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                            }
                            HStack(spacing: 8) {
                                Text(event.target.rawValue)
                                    .font(.subheadline.weight(.black))
                                Text(event.operation.rawValue)
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(AOSTheme.gold)
                            }
                            Text(event.summary)
                                .font(.caption)
                                .foregroundStyle(AOSTheme.muted)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .aosPanel(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                    .aosHoverable(cornerRadius: 14)
                }
            }
            .padding(14)
        }
    }
}

/// Every asset in the catalog with search and preview (Assets nav item).
struct GlobalAssetsColumn: View {
    @EnvironmentObject private var state: AppState

    private var assets: [Asset] {
        let all = state.catalog.assets.sorted { $0.createdAt > $1.createdAt }
        guard !state.searchText.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(state.searchText)
                || $0.originalFilename.localizedCaseInsensitiveContains(state.searchText)
        }
    }

    private func songTitle(for asset: Asset) -> String? {
        guard let songID = asset.songID else { return nil }
        return state.catalog.songs.first { $0.id == songID }?.title
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if assets.isEmpty {
                    Text("No assets in the library yet. Import a folder to bring in recordings, beats, and mixes.")
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                        .padding(14)
                }
                ForEach(assets) { asset in
                    Button {
                        state.selectedAssetID = asset.id
                        if let songID = asset.songID {
                            state.selectedSongID = songID
                        }
                    } label: {
                        HStack(spacing: 10) {
                            PlayButton(asset: asset)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.title)
                                    .font(.subheadline.weight(.bold))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if let title = songTitle(for: asset) {
                                        Text(title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(AOSTheme.gold)
                                            .lineLimit(1)
                                    }
                                    Text(asset.role.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(AOSTheme.muted)
                                }
                            }
                            Spacer()
                            if let duration = asset.duration {
                                Text(InspectorView.mmss(duration))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AOSTheme.muted)
                            }
                        }
                        .padding(11)
                        .aosPanel(cornerRadius: 13)
                    }
                    .buttonStyle(.plain)
                    .aosHoverable(cornerRadius: 13)
                    .draggable(asset.id.uuidString)
                }
            }
            .padding(14)
        }
    }
}

/// Honest placeholder for the planned DNA feature.
struct DNAPlaceholderColumn: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 34))
                .foregroundStyle(AOSTheme.gold)
            Text("Creative DNA")
                .font(.headline.weight(.black))
            Text("Cross-song patterns in your catalog — recurring keys, tempos, structures, and sounds. Planned after observed-change history accumulates.")
                .font(.caption)
                .foregroundStyle(AOSTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
