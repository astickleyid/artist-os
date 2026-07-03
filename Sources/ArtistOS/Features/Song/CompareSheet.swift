import SwiftUI

/// Side-by-side candidate comparison for a master slot, following the
/// reference-comparison pattern from mastering tools (Metric AB, Ozone):
/// instant A/B source switching at a held playhead position, then commit.
struct CompareSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioPreviewService
    @Environment(\.dismiss) private var dismiss

    let song: Song
    let section: MasterSection

    @State private var assetAID: UUID?
    @State private var assetBID: UUID?

    private var candidates: [Asset] { state.assets(for: song.id) }
    private var assetA: Asset? { state.asset(id: assetAID) }
    private var assetB: Asset? { state.asset(id: assetBID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Compare — \(section.name)")
                    .font(.title3.weight(.black))
                Text("Switch sources without losing the playhead. Choose a side to lock the slot.")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
            }

            if candidates.count < 2 {
                Text("This song needs at least two assets to run a comparison. Import more takes first.")
                    .font(.subheadline)
                    .foregroundStyle(AOSTheme.muted)
                    .padding(.vertical, 20)
            } else {
                HStack(spacing: 12) {
                    candidateCard(label: "A", asset: assetA, tint: AOSTheme.gold,
                                  selection: $assetAID, shortcut: "a")
                    candidateCard(label: "B", asset: assetB, tint: AOSTheme.blue,
                                  selection: $assetBID, shortcut: "b")
                }
            }

            HStack {
                Button("Keep Undecided") { close() }
                Spacer()
                if let assetA {
                    Button("Choose A") { choose(assetA) }
                        .buttonStyle(.borderedProminent)
                        .tint(AOSTheme.gold)
                }
                if let assetB {
                    Button("Choose B") { choose(assetB) }
                        .buttonStyle(.borderedProminent)
                        .tint(AOSTheme.blue)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: seedDefaults)
        .onDisappear { audio.stop() }
    }

    private func candidateCard(
        label: String,
        asset: Asset?,
        tint: Color,
        selection: Binding<UUID?>,
        shortcut: KeyEquivalent
    ) -> some View {
        let isActive = asset != nil && audio.playingAssetID == asset?.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.title2.weight(.black))
                    .foregroundStyle(tint)
                Spacer()
                Picker("", selection: selection) {
                    Text("Pick asset…").tag(UUID?.none)
                    ForEach(candidates) { candidate in
                        Text(candidate.title).tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }

            if let asset {
                WaveformView(asset: asset, tint: tint)
                    .frame(height: 34)
                Text(asset.originalFilename)
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
                    .lineLimit(1)
                Button {
                    if isActive {
                        if audio.isPlaying { audio.pause() } else { audio.resume() }
                    } else {
                        audio.switchPreview(to: asset)
                    }
                } label: {
                    Label(
                        isActive && audio.isPlaying ? "Pause" : "Listen \(label)",
                        systemImage: isActive && audio.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .keyboardShortcut(shortcut, modifiers: [])
                .disabled(!audio.canPlay(asset))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 34)
                Text("No candidate selected")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aosPanel(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isActive ? tint : .clear, lineWidth: 2)
        )
    }

    private func seedDefaults() {
        let ids = candidates.map(\.id)
        assetAID = section.assetID ?? ids.first
        assetBID = ids.first { $0 != assetAID } ?? ids.dropFirst().first
    }

    private func choose(_ winner: Asset) {
        state.resolveDecision(sectionID: section.id, songID: song.id, winner: winner.id)
        close()
    }

    private func close() {
        audio.stop()
        dismiss()
    }
}
