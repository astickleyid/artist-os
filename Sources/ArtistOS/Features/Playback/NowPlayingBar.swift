import SwiftUI

/// Persistent playback strip pinned to the window bottom while any preview is
/// active — the Splice/Apple Music convention, so playback control never
/// depends on which panel you're looking at.
struct NowPlayingBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioPreviewService

    private var asset: Asset? { state.asset(id: audio.playingAssetID) }

    private var songTitle: String? {
        guard let songID = asset?.songID else { return nil }
        return state.catalog.songs.first { $0.id == songID }?.title
    }

    var body: some View {
        if let asset {
            HStack(spacing: 14) {
                Button {
                    if audio.isPlaying { audio.pause() } else { audio.resume() }
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(AOSTheme.gold)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(audio.isPlaying ? "Pause (Space)" : "Play (Space)")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(AOSTheme.gold)
                            .symbolEffect(.variableColor.iterative, isActive: audio.isPlaying)
                        Text(asset.title)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                    }
                    if let songTitle {
                        Text(songTitle)
                            .font(.caption2)
                            .foregroundStyle(AOSTheme.muted)
                            .lineLimit(1)
                    }
                }
                .frame(width: 200, alignment: .leading)

                Text(InspectorView.mmss(audio.currentTime))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AOSTheme.muted)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        if audio.duration > 0 {
                            Capsule()
                                .fill(AOSTheme.gold)
                                .frame(width: geo.size.width * min(1, audio.currentTime / audio.duration))
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
                }
                .frame(height: 7)

                Text(InspectorView.mmss(audio.duration))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AOSTheme.muted)

                Button {
                    audio.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AOSTheme.muted)
                }
                .buttonStyle(.plain)
                .help("Stop preview")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle().fill(AOSTheme.line).frame(height: 1)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
