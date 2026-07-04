import SwiftUI
import AppKit

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioPreviewService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.caption.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)

            if let song = state.selectedSong {
                inspectorCard(title: "Current Risk") {
                    Text(song.risk).font(.headline.weight(.bold))
                }
                inspectorCard(title: "Master Progress") {
                    AOSProgressBar(value: song.progress)
                    Text("\(Int(song.progress * 100))% locked")
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                }
            }

            inspectorCard(title: "Selected Asset") {
                if let asset = state.selectedAsset {
                    assetDetail(asset)
                } else {
                    Text("Select a master section or asset to inspect metadata.")
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func assetDetail(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PlayButton(asset: asset)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.title).font(.headline.weight(.bold))
                    Text(asset.originalFilename)
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                        .lineLimit(2)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    WaveformView(asset: asset)
                    if audio.playingAssetID == asset.id, audio.duration > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * min(1, audio.currentTime / audio.duration))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard geo.size.width > 0 else { return }
                            audio.seek(asset: asset, toFraction: value.location.x / geo.size.width)
                        }
                )
                .allowsHitTesting(audio.canPlay(asset))
            }
            .frame(height: 36)
            .help("Click or drag to scrub")

            if audio.playingAssetID == asset.id, audio.duration > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    AOSProgressBar(value: audio.currentTime / audio.duration)
                    Text("\(Self.mmss(audio.currentTime)) / \(Self.mmss(audio.duration))")
                        .font(.caption2)
                        .foregroundStyle(AOSTheme.muted)
                }
            }

            AOSBadge(text: asset.role.rawValue, tint: AOSTheme.blue)

            VStack(alignment: .leading, spacing: 4) {
                if let format = asset.format, !format.isEmpty {
                    metadataRow("Format", format)
                }
                if let duration = asset.duration {
                    metadataRow("Duration", Self.mmss(duration))
                }
                if let size = asset.fileSize {
                    metadataRow("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let sampleRate = asset.sampleRate {
                    metadataRow("Sample Rate", String(format: "%.1f kHz", sampleRate / 1000))
                }
                if let bpm = asset.bpm {
                    metadataRow("Tempo", "\(Int(bpm.rounded())) BPM")
                }
                if let key = asset.musicalKey {
                    metadataRow("Key", key)
                }
                if let channels = asset.channels {
                    metadataRow("Channels", channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels)")
                }
                metadataRow("Added", asset.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .padding(.top, 2)

            if let path = asset.sourcePath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(AOSTheme.muted)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
        }
    }

    static func mmss(_ time: TimeInterval) -> String {
        let seconds = Int(time.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func inspectorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .aosPanel(cornerRadius: 16)
    }
}
